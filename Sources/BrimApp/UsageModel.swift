import Combine
import Foundation
import IslandCore
import IslandServices

/// How a connection is doing, for Settings and the menu.
enum ConnectionState: Equatable {
    case off
    case checking
    case connected(String)
    case attention(String)

    var summary: String {
        switch self {
        case .off: return "Disconnected"
        case .checking: return "Connecting…"
        case .connected(let detail): return detail
        case .attention(let problem): return problem
        }
    }
}

/// Runs every connection: scans logs on a background queue, fetches account usage on a slower
/// cadence, merges both into one snapshot and raises events when something changes.
@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot.empty
    @Published private(set) var states: [String: ConnectionState] = [:]
    @Published private(set) var claudeConnection: ClaudeStatusLineSetup.State = .notConnected
    /// The event the island is showing right now.
    @Published private(set) var event: IslandEvent?
    /// Daily highest plan use per account, for the AI tab's 14-day chart.
    @Published private(set) var quotaHistory = QuotaHistory.load(from: UsageModel.quotaHistoryURL)
    private var quotaHistorySaved = Date.distantPast

    static var quotaHistoryURL: URL { supportDirectory.appendingPathComponent("quota-history.json") }

    let settings: AppSettings
    let statusLine: ClaudeStatusLineSetup

    /// Compact wing scans today only; expand loads the full history window.
    private let engine = UsageEngine(
        historyDays: UsageEngine.compactHistoryDays,
        checkpointURL: UsageCollector.defaultCheckpointURL
    )
    private let queue = DispatchQueue(label: "brim.usage", qos: .utility)
    private var timer: Timer?
    private var isScanning = false
    private var scanAgain = false
    private var wantsExpandedHistory = false
    private var cancellables = Set<AnyCancellable>()

    private var logTools: [String: ToolSnapshot] = [:]
    private var accountUsage: [String: AccountUsage] = [:]
    private var accountErrors: [String: String] = [:]
    private var lastAccountFetch: [String: Date] = [:]
    private var fetching = Set<String>()
    /// Connections the user just connected; they get a "connected" moment once data arrives.
    private var justConnected = Set<String>()
    private var moments = MomentQueue()
    private var limitAlerts = LimitAlertMemory()
    private var eventTask: Task<Void, Never>?
    private var gapTask: Task<Void, Never>?
    /// Why moments are on hold (the island is expanded, hidden in full screen, …).
    private var pauseReasons = Set<String>()

    /// Claude accounts by connection ID, and their limits as Anthropic last reported them.
    private var claudeAccounts: [String: ClaudeAccount] = [:]
    private var claudeLimits: [String: [PlanWindow]] = [:]
    private var claudeErrors: [String: String] = [:]
    private var claudeLimitsCache = ClaudeLimitsCache.load(from: ClaudeLimitsCache.defaultURL(supportDirectory: UsageModel.supportDirectory))
    /// Claude cards the user switched away from the Settings default.
    @Published private var claudeStyleOverrides: [String: ClaudeCardStyle] = [:]

    /// Account services are polled gently; logs are cheap and read every few seconds.
    private static let accountInterval: TimeInterval = 300
    private static let milestones: [Int64] = [1_000_000, 5_000_000, 10_000_000, 25_000_000, 50_000_000, 100_000_000, 250_000_000, 500_000_000]
    private static let thresholds: [Double] = [80, 95, 100]

    static var supportDirectory: URL { ClaudeStatusLineSetup.defaultSupportDirectory }

    init(settings: AppSettings) {
        self.settings = settings
        statusLine = ClaudeStatusLineSetup(
            supportDirectory: Self.supportDirectory,
            settingsURL: ClaudeStatusLineSetup.defaultSettingsURL()
        )

        settings.$connections
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        settings.$refreshSeconds
            .removeDuplicates()
            .sink { [weak self] seconds in self?.scheduleTimer(every: seconds) }
            .store(in: &cancellables)
    }

    func start() {
        if BrimQA.skipCredentials {
            // Fixture-only island / Overview — no Keychain, OAuth, or account APIs.
            snapshot = BrimQA.fixtureSnapshot()
            return
        }
        refresh(forceAccounts: true)
    }

    private func scheduleTimer(every seconds: Double) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(2, seconds), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = seconds * 0.2
    }

    // MARK: - Refresh

    func refresh(forceAccounts: Bool = false) {
        if BrimQA.skipCredentials {
            snapshot = BrimQA.fixtureSnapshot()
            return
        }
        settings.reloadIfChangedOnDisk()
        claudeConnection = statusLine.state()
        scanLogs()
        let now = Date()
        for connection in settings.enabledConnections where connection.kind.source == .account || connection.kind == .claude {
            let due = (lastAccountFetch[connection.id] ?? .distantPast) < now.addingTimeInterval(-Self.accountInterval)
            guard forceAccounts || due else { continue }
            if connection.kind == .claude { fetchClaudeLimits(connection) } else { fetchAccount(connection) }
        }
        publish()
    }

    /// Compact island keeps a 1-day window; opening the panel loads 30 days (lazy history).
    func setExpandedHistory(_ expanded: Bool) {
        if BrimQA.skipCredentials { return }
        wantsExpandedHistory = expanded
        let target = expanded ? UsageEngine.fullHistoryDays : UsageEngine.compactHistoryDays
        guard engine.historyDays != target else { return }
        let engine = self.engine
        let queue = self.queue
        queue.async {
            engine.setHistoryDays(target)
        }
        scanLogs()
    }

    private func scanLogs() {
        if BrimQA.skipCredentials { return }
        guard !isScanning else {
            scanAgain = true
            return
        }
        isScanning = true

        let enabled = settings.enabledConnections
        let planWindows = statusLine.planWindows()
        let engine = self.engine
        let queue = self.queue
        let targetDays = wantsExpandedHistory ? UsageEngine.fullHistoryDays : UsageEngine.compactHistoryDays
        Task {
            let tools = await withCheckedContinuation { (continuation: CheckedContinuation<[ToolSnapshot], Never>) in
                queue.async {
                    if engine.historyDays != targetDays {
                        engine.setHistoryDays(targetDays)
                    }
                    let scanned = UsageCollector.scanLogs(
                        engine: engine,
                        connections: enabled,
                        statusLineWindows: planWindows
                    )
                    continuation.resume(returning: scanned)
                }
            }
            self.logTools = Dictionary(tools.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            self.isScanning = false
            self.publish()
            if self.scanAgain {
                self.scanAgain = false
                self.scanLogs()
            }
        }
    }

    private func fetchAccount(_ connection: Connection) {
        if BrimQA.skipCredentials { return }
        guard !fetching.contains(connection.id) else { return }
        fetching.insert(connection.id)
        publish()
        Task {
            do {
                let usage = try await AccountFetcher.fetch(connection)
                self.accountUsage[connection.id] = usage
                self.accountErrors[connection.id] = nil
            } catch {
                self.accountErrors[connection.id] = error.localizedDescription
            }
            self.lastAccountFetch[connection.id] = Date()
            self.fetching.remove(connection.id)
            self.publish()
        }
    }

    /// Reads who is signed in to the connection's Claude Code folder, then asks Anthropic for its limits.
    private func fetchClaudeLimits(_ connection: Connection) {
        if BrimQA.skipCredentials { return }
        guard !fetching.contains(connection.id), let configDir = connection.claudeConfigDir() else { return }
        fetching.insert(connection.id)
        Task {
            let account = await Task.detached { ClaudeAccounts.account(configDir: configDir) }.value
            // Email may arrive only after OAuth finishes writing `.claude.json` — check when known.
            if self.adoptClaudeEmailIfNeeded(for: connection.id, email: account.email) != nil {
                self.fetching.remove(connection.id)
                return
            }
            self.claudeAccounts[connection.id] = account
            do {
                let windows = try await ClaudeUsageFetcher.fetch(account)
                self.claudeLimits[connection.id] = windows
                self.claudeErrors[connection.id] = nil
                self.claudeLimitsCache.readings[account.key] = .init(windows: windows, fetchedAt: Date())
                self.claudeLimitsCache.save(to: ClaudeLimitsCache.defaultURL(supportDirectory: Self.supportDirectory))
            } catch {
                self.claudeLimits[connection.id] = nil
                self.claudeErrors[connection.id] = error.localizedDescription
            }
            self.lastAccountFetch[connection.id] = Date()
            self.fetching.remove(connection.id)
            self.publish()
        }
    }

    /// Fills in a Claude card's account, plan label and limits (live, else the last reading until it resets).
    private func applyClaudeAccount(to tool: inout ToolSnapshot, connection: Connection) {
        guard connection.kind == .claude else { return }
        UsageCollector.applyClaudeLimits(
            to: &tool,
            account: claudeAccounts[connection.id],
            live: claudeLimits[connection.id],
            cached: claudeAccounts[connection.id].flatMap { claudeLimitsCache.readings[$0.key] },
            failure: claudeErrors[connection.id],
            planName: tool.planName
        )
    }

    /// Merges log and account data in the user's order and raises events for what changed.
    private func publish() {
        if BrimQA.skipCredentials {
            snapshot = BrimQA.fixtureSnapshot()
            return
        }
        var tools: [ToolSnapshot] = []
        var newStates: [String: ConnectionState] = [:]

        for connection in settings.connections {
            guard connection.isEnabled else {
                newStates[connection.id] = .off
                continue
            }
            var tool: ToolSnapshot
            if connection.kind.source == .localLogs {
                tool = logTools[connection.id] ?? ToolSnapshot(id: connection.id, kind: connection.kind, name: connection.name)
                tool.kind = connection.kind
                tool.name = connection.name
                if logTools[connection.id] == nil {
                    newStates[connection.id] = .checking
                } else if tool.hasData {
                    newStates[connection.id] = .connected("\(tool.logFileCount) log files")
                } else if connection.kind == .claude {
                    // Plan limits come from OAuth; local logs are optional session detail only.
                    newStates[connection.id] = .checking
                    tool.statusMessage = "Fetching plan limits…"
                } else {
                    newStates[connection.id] = .attention("No logs found yet")
                    tool.statusMessage = "No logs found yet. Use \(connection.kind.displayName) once, or set its folder in Settings."
                }
            } else {
                let error = accountErrors[connection.id]
                tool = .account(id: connection.id, kind: connection.kind, name: connection.name,
                                usage: accountUsage[connection.id], statusMessage: error)
                if fetching.contains(connection.id), accountUsage[connection.id] == nil {
                    newStates[connection.id] = .checking
                } else if let error {
                    newStates[connection.id] = .attention(error)
                } else if let updated = accountUsage[connection.id]?.fetchedAt {
                    newStates[connection.id] = .connected("Updated \(Format.ago(updated))")
                } else {
                    newStates[connection.id] = .checking
                }
            }
            if let tier = Plans.tier(connection.planID, for: connection.kind) {
                tool.planName = tier.name
            }
            applyClaudeAccount(to: &tool, connection: connection)
            if connection.kind == .claude {
                if tool.tightestWindow != nil {
                    // OAuth plan limits are enough to count as connected — local jsonl is optional.
                    tool.hasData = true
                    tool.statusMessage = nil
                    if case .checking = newStates[connection.id] {
                        newStates[connection.id] = .connected("Plan limits")
                    } else if case .attention("No logs found yet") = newStates[connection.id] {
                        newStates[connection.id] = .connected("Plan limits")
                    }
                } else if let failure = claudeErrors[connection.id] {
                    tool.statusMessage = failure
                    newStates[connection.id] = .attention(failure)
                }
            }
            tools.append(tool)
        }

        let sources = settings.enabledConnections.compactMap { c in c.logSource().map { (id: c.id, source: $0) } }
        let next = UsageSnapshot(tools: tools, generatedAt: Date(), coveredIDs: LogSource.coveredIDs(in: sources))
        detectEvents(old: snapshot, new: next)
        snapshot = next
        states = newStates
        recordQuotaHistory(next)
    }

    private func recordQuotaHistory(_ snapshot: UsageSnapshot) {
        var history = quotaHistory
        var changed = false
        for tool in snapshot.tools {
            if let lead = tool.tightestWindow?.usedPercent, history.record(tool.id, percent: lead) { changed = true }
        }
        guard changed else { return }
        quotaHistory = history
        // Written at most once a minute; a lost reading only lowers one day's peak.
        if Date().timeIntervalSince(quotaHistorySaved) > 60 {
            quotaHistorySaved = Date()
            history.save(to: Self.quotaHistoryURL)
        }
    }

    // MARK: - Events

    private func detectEvents(old: UsageSnapshot, new: UsageSnapshot) {
        for tool in new.tools {
            if justConnected.contains(tool.id), tool.hasData || tool.statusMessage != nil {
                justConnected.remove(tool.id)
                if tool.hasData {
                    let detail = tool.planName.map { "\($0) plan" } ?? (tool.hasTokenData ? Format.tokens(tool.today.total) + " tokens today" : "Connected")
                    enqueue(.connected(connectionID: tool.id, kind: tool.kind, name: tool.name, detail: detail))
                }
            }
            for window in tool.planWindows {
                limitAlerts.observe(connectionID: tool.id, window: window)
            }
            // Only compare against data we had before; the first load never fires events.
            guard old.generatedAt != .distantPast, let previous = old[tool.id], previous.hasData else { continue }

            for window in tool.planWindows {
                let before = previous.planWindows.first { $0.label == window.label }?.usedPercent ?? window.usedPercent
                guard let crossed = Self.thresholds.last(where: { before < $0 && window.usedPercent >= $0 }),
                      limitAlerts.shouldAnnounce(connectionID: tool.id, window: window, threshold: crossed)
                else { continue }
                let countdown = window.resetsAt.map { Format.countdown(to: $0) }
                let reset = countdown.map { "resets in \($0)" } ?? ""
                if crossed >= 100 {
                    enqueue(IslandEvent(connectionID: tool.id, kind: tool.kind, style: .limit,
                                        title: "\(window.label) limit", detail: countdown.map { "back in \($0)" } ?? tool.name))
                } else {
                    enqueue(IslandEvent(connectionID: tool.id, kind: tool.kind, style: .warning,
                                        title: "\(window.label) \(Format.percent(window.usedPercent)) used", detail: reset.isEmpty ? tool.name : reset))
                }
            }

            if tool.hasTokenData,
               let milestone = Self.milestones.last(where: { previous.today.total < $0 && tool.today.total >= $0 }) {
                enqueue(IslandEvent(connectionID: tool.id, kind: tool.kind, style: .milestone,
                                    title: "\(Format.tokens(milestone)) tokens", detail: "\(tool.name) today"))
            }
        }
    }

    private func enqueue(_ event: IslandEvent) {
        moments.enqueue(event)
        syncMoment()
    }

    /// Publishes the current moment and schedules the end of it.
    private func syncMoment() {
        if event != moments.current { event = moments.current }
        eventTask?.cancel()
        eventTask = nil
        guard let left = moments.timeLeft() else { return }
        eventTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.moments.finishCurrent()
            self.event = nil
            self.gapTask = Task { [weak self] in
                // A short gap so consecutive events read as separate moments.
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard let self, self.moments.current == nil else { return }
                self.moments.showNext()
                self.syncMoment()
            }
        }
    }

    func dismissEvent() {
        moments.dismiss()
        syncMoment()
    }

    /// Holds moments while `reason` applies (the island is expanded or hidden), so none expire unseen.
    func setMomentsPaused(_ paused: Bool, reason: String) {
        if paused { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        if pauseReasons.isEmpty { moments.resume() } else { moments.pause() }
        syncMoment()
    }

    // MARK: - Connections

    /// Connects (or reconnects) a connection, optionally saving a token for it first.
    func connect(_ id: String, token: String? = nil) {
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            Keychain.save(token, for: id)
        }
        accountErrors[id] = nil
        lastAccountFetch[id] = nil
        justConnected.insert(id)
        if settings.connection(id)?.isEnabled == true {
            refresh(forceAccounts: true)
        } else {
            settings.setEnabled(id, true) // the connections sink refreshes
            if let connection = settings.connection(id), connection.kind.source == .account { fetchAccount(connection) }
        }
    }

    /// Stops tracking a connection but keeps it (and its token) for later.
    func disconnect(_ id: String) {
        guard let connection = settings.connection(id) else { return }
        settings.setEnabled(id, false)
        justConnected.remove(id)
        enqueue(IslandEvent(connectionID: id, kind: connection.kind, style: .disconnected, title: "\(connection.name)", detail: "disconnected"))
    }

    /// Forgets a connection and its saved token.
    func remove(_ id: String) {
        Keychain.delete(id)
        accountUsage[id] = nil
        accountErrors[id] = nil
        lastAccountFetch[id] = nil
        logTools[id] = nil
        limitAlerts.forget(connectionID: id)
        settings.remove(id)
    }

    func disconnectAll() {
        settings.setAllEnabled(false)
        justConnected.removeAll()
    }

    func connectAll() {
        for connection in settings.connections where !connection.isEnabled {
            justConnected.insert(connection.id)
            lastAccountFetch[connection.id] = nil
        }
        settings.setAllEnabled(true)
        refresh(forceAccounts: true)
    }

    /// Adds a connection (any number, any mix of tools) and connects it.
    @discardableResult
    func add(_ kind: ToolKind) -> Connection {
        let connection = settings.add(kind)
        justConnected.insert(connection.id)
        if kind.source == .account { fetchAccount(connection) }
        return connection
    }

    /// Adds a connection with its options and token in one go, from the Add Account window.
    @discardableResult
    func addAccount(_ kind: ToolKind, options: [String: String] = [:], token: String? = nil) -> Connection {
        var connection = settings.add(kind)
        if !options.isEmpty {
            connection.options.merge(options) { $1 }
            settings.update(connection)
        }
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            Keychain.save(token, for: connection.id)
        }
        justConnected.insert(connection.id)
        if kind.source == .account { fetchAccount(connection) }
        return connection
    }

    /// Signs an existing connection in again: a new token, or a different GitHub CLI account.
    func reconnect(_ id: String, options: [String: String] = [:], token: String? = nil) {
        guard var connection = settings.connection(id) else { return }
        if !options.isEmpty {
            connection.options.merge(options) { $1 }
            settings.update(connection)
        }
        let token = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A saved token wins over the GitHub CLI, so picking a CLI account drops it.
        if token.isEmpty, options[Connection.Option.githubLogin] != nil { Keychain.delete(id) }
        connect(id, token: token)
    }

    /// Accounts that are connected already, so the Add Account window can mark them.
    func connectedGitHubLogins() -> Set<String> {
        var logins = Set<String>()
        for connection in settings.connections where connection.kind == .copilot {
            let login = connection.option(Connection.Option.githubLogin)
            if !login.isEmpty { logins.insert(login) }
            if let reported = snapshot[connection.id]?.accountLabel { logins.insert(reported) }
        }
        return logins
    }

    func connectClaudePlan() throws {
        try statusLine.connect()
        claudeConnection = statusLine.state()
    }

    func disconnectClaudePlan() throws {
        try statusLine.disconnect()
        claudeConnection = statusLine.state()
        refresh()
    }

    // MARK: - Display helpers

    /// The short text for one connection in the compact island and the menu bar.
    func compactValue(for tool: ToolSnapshot) -> String {
        guard tool.hasData else { return tool.statusMessage != nil ? "sign in" : "–" }
        let billing = settings.connection(tool.id).map(Plans.billing(for:)) ?? .usageWindows
        let tokens = Format.tokens(tool.today.total)
        let percent = tool.tightestWindow.map { Format.percent($0.usedPercent) }

        switch settings.compactMetric {
        case .tokens:
            return tool.hasTokenData ? tokens : (tool.tightestWindow?.detail ?? percent ?? "–")
        case .plan:
            return percent ?? (tool.hasTokenData ? tokens : "–")
        case .auto:
            switch billing {
            case .payAsYouGo:
                return tool.hasTokenData ? tokens : (tool.tightestWindow?.detail ?? percent ?? "–")
            case .usageWindows, .allowance:
                return percent ?? (tool.hasTokenData ? tokens : "–")
            }
        }
    }

    /// Connected tools, most urgent first: pinned, then near a limit or working, then the user's order.
    var featuredTools: [ToolSnapshot] {
        let tools = snapshot.tools
        let now = Date()
        func rank(_ tool: ToolSnapshot) -> Int {
            if tool.id == settings.pinnedID { return 0 }
            let tightest = tool.tightestWindow?.usedPercent ?? 0
            if tightest >= 95 { return 1 }
            if let last = tool.lastActivity, now.timeIntervalSince(last) < 120 { return 2 }
            if tightest >= 80 { return 3 }
            if tool.statusMessage != nil && !tool.hasData { return 4 }
            return 5
        }
        return tools.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// "used" after a plan value; otherwise tells apart two connections of the same tool ("core", "work").
    func wingSuffix(for tool: ToolSnapshot) -> String? {
        if tool.hasData, tool.tightestWindow != nil, !(tool.hasTokenData && compactValue(for: tool) == Format.tokens(tool.today.total)) {
            return "used"
        }
        guard snapshot.tools.filter({ $0.kind == tool.kind }).count > 1 else { return nil }
        var name = tool.name
        for prefix in [tool.kind.displayName, tool.kind.shortName] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        let word = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map { String($0.prefix(5)).lowercased() }
        return word?.isEmpty == false ? word : nil
    }

    /// The account to show for a connection, unless the user hid emails.
    func accountLabel(for id: String) -> String? {
        guard settings.showAccountEmails else { return nil }
        return snapshot[id]?.accountLabel.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Claude

    /// Whether a Claude card shows the full `/usage`-style view.
    func claudeStyle(for id: String) -> ClaudeCardStyle {
        claudeStyleOverrides[id] ?? settings.claudeCardStyle
    }

    func toggleClaudeStyle(for id: String) {
        claudeStyleOverrides[id] = claudeStyle(for: id) == .full ? .short : .full
    }

    func setClaudeStyle(_ style: ClaudeCardStyle, for id: String) {
        claudeStyleOverrides[id] = style
    }

    /// Adds a connection for a Claude account that just signed in (from the Add Account window).
    /// Refuses a second connection for the same auth email (caller must show the error to the user).
    @discardableResult
    func addClaudeConnection(for account: ClaudeAccount) throws -> Connection {
        if let email = account.email,
           let existing = ClaudeDuplicateEmail.existing(email: email, in: settings.connections) {
            // Same folder → reconnect; different folder / duplicate sign-in → refuse.
            if !ClaudeDuplicateEmail.isDuplicate(
                email: email,
                candidateConfigDir: account.configDir,
                against: existing
            ) {
                var updated = existing
                updated.options[Connection.Option.accountEmail] = AccountEmail.normalize(email)
                settings.update(updated)
                connect(existing.id)
                return updated
            }
            throw ClaudeAccountSetupError.duplicateEmail(AccountEmail.normalize(email))
        }
        let existing = settings.connections.first { $0.kind == .claude && $0.claudeConfigDir()?.standardizedFileURL == account.configDir.standardizedFileURL }
        if let existing {
            var updated = existing
            if let email = account.email { updated.options[Connection.Option.accountEmail] = AccountEmail.normalize(email) }
            settings.update(updated)
            connect(existing.id)
            return updated
        }
        var connection = settings.add(.claude)
        connection.name = account.suggestedName
        connection.options[Connection.Option.configDir] = account.configDir.path
        if let email = account.email {
            connection.options[Connection.Option.accountEmail] = AccountEmail.normalize(email)
        }
        settings.update(connection)
        claudeAccounts[connection.id] = account
        justConnected.insert(connection.id)
        fetchClaudeLimits(connection)
        return connection
    }

    /// When an email becomes known after OAuth/logs (was missing at add time), store it or refuse the duplicate.
    /// Returns a user-visible message when this connection was removed as a duplicate.
    @discardableResult
    func adoptClaudeEmailIfNeeded(for connectionID: String, email: String?) -> String? {
        guard let email, !email.isEmpty,
              var connection = settings.connection(connectionID),
              connection.kind == .claude
        else { return nil }
        let normalized = AccountEmail.normalize(email)
        if connection.accountEmail == normalized { return nil }
        if let other = ClaudeDuplicateEmail.existing(email: normalized, in: settings.connections, excluding: connectionID),
           ClaudeDuplicateEmail.isDuplicate(email: normalized, candidateConfigDir: connection.claudeConfigDir(), against: other) {
            // Late-discovered collision: keep the other connection, remove this one, tell the user.
            settings.remove(connectionID)
            claudeAccounts.removeValue(forKey: connectionID)
            claudeLimits.removeValue(forKey: connectionID)
            claudeErrors.removeValue(forKey: connectionID)
            publish()
            let message = ClaudeDuplicateEmail.userMessage(email: normalized)
            ClaudeDuplicateEmailUI.report(message)
            return message
        }
        connection.options[Connection.Option.accountEmail] = normalized
        settings.update(connection)
        return nil
    }

    func isWorking(_ tool: ToolSnapshot) -> Bool {
        guard let last = tool.lastActivity else { return false }
        return Date().timeIntervalSince(last) < 120
    }
}

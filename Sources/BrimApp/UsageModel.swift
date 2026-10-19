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

    let settings: AppSettings
    let statusLine: ClaudeStatusLineSetup

    private let engine = UsageEngine(historyDays: 30)
    private let queue = DispatchQueue(label: "brim.usage", qos: .utility)
    private var timer: Timer?
    private var isScanning = false
    private var scanAgain = false
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
        settings.reloadIfChangedOnDisk()
        claudeConnection = statusLine.state()
        scanLogs()
        let now = Date()
        for connection in settings.enabledConnections where connection.kind.source == .account {
            let due = (lastAccountFetch[connection.id] ?? .distantPast) < now.addingTimeInterval(-Self.accountInterval)
            if forceAccounts || due { fetchAccount(connection) }
        }
        publish()
    }

    private func scanLogs() {
        guard !isScanning else {
            scanAgain = true
            return
        }
        isScanning = true

        let enabled = settings.enabledConnections
        let sources = enabled.compactMap { c in c.logSource().map { (id: c.id, source: $0) } }
        // Claude Code's status line reports plan limits for its default folder only.
        let planWindows = statusLine.planWindows()
        let external = Dictionary(enabled.filter { $0.kind == .claude && $0.usesDefaultLocation }.map { ($0.id, planWindows) },
                                  uniquingKeysWith: { first, _ in first })
        let engine = self.engine
        let queue = self.queue
        Task {
            let tools = await withCheckedContinuation { (continuation: CheckedContinuation<[ToolSnapshot], Never>) in
                queue.async {
                    engine.configure(sources)
                    engine.externalPlanWindows = external
                    engine.scan()
                    continuation.resume(returning: engine.snapshot())
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

    /// Merges log and account data in the user's order and raises events for what changed.
    private func publish() {
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
            tools.append(tool)
        }

        let next = UsageSnapshot(tools: tools, generatedAt: Date())
        detectEvents(old: snapshot, new: next)
        snapshot = next
        states = newStates
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
                                        title: "\(window.label) \(Format.percent(window.usedPercent))", detail: reset.isEmpty ? tool.name : reset))
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

    /// Tells apart two connections of the same tool in the wings ("core", "work").
    func wingSuffix(for tool: ToolSnapshot) -> String? {
        guard snapshot.tools.filter({ $0.kind == tool.kind }).count > 1 else { return nil }
        var name = tool.name
        for prefix in [tool.kind.displayName, tool.kind.shortName] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        let word = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map { String($0.prefix(5)).lowercased() }
        return word?.isEmpty == false ? word : nil
    }

    func isWorking(_ tool: ToolSnapshot) -> Bool {
        guard let last = tool.lastActivity else { return false }
        return Date().timeIntervalSince(last) < 120
    }
}

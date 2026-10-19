import Foundation
import IslandCore
import IslandServices

// `brim`: connect AI tools and check usage from the terminal. It edits the same connections
// file as the app, so changes show up on the island within one refresh.

let version = "0.2.0"
BrimMigration.run()
if URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "ai-island" {
    FileHandle.standardError.write(Data("ai-island is now called brim. The old name still works for now.\n".utf8))
}
let store = ConnectionStore()
var file = store.load()
var arguments = Array(CommandLine.arguments.dropFirst())
let useColor = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

// MARK: - Output helpers

func paint(_ text: String, _ code: String) -> String { useColor ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
func bold(_ text: String) -> String { paint(text, "1") }
func dim(_ text: String) -> String { paint(text, "2") }
func green(_ text: String) -> String { paint(text, "32") }
func amber(_ text: String) -> String { paint(text, "33") }
func red(_ text: String) -> String { paint(text, "31") }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((red("error: ") + message + "\n").utf8))
    exit(1)
}

func save() {
    do { try store.save(file) } catch { fail("Couldn't save \(store.url.path): \(error.localizedDescription)") }
}

/// Removes `--name value` from the arguments and returns the value.
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: "--\(name)") else { return nil }
    guard index + 1 < arguments.count else { fail("--\(name) needs a value") }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}

/// Removes a `--flag` and says whether it was there.
func flag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: "--\(name)") else { return false }
    arguments.remove(at: index)
    return true
}

func positional(_ index: Int, _ what: String) -> String {
    guard arguments.count > index else { fail("missing \(what). Run `brim help`.") }
    return arguments[index]
}

func find(_ query: String) -> Connection {
    guard let connection = file.find(query) else {
        fail("no connection named \"\(query)\". Run `brim list` to see them.")
    }
    return connection
}

func update(_ connection: Connection) {
    if let index = file.connections.firstIndex(where: { $0.id == connection.id }) {
        file.connections[index] = connection
    }
}

/// Runs async work from this synchronous command-line program and waits for the result.
final class ResultBox<T>: @unchecked Sendable { var value: T? }
func runBlocking<T>(_ body: @escaping @Sendable () async -> T) -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        box.value = await body()
        done.signal()
    }
    done.wait()
    return box.value!
}

/// A token from --token, --token-stdin, or a hidden prompt when `ask` is true and we're in a terminal.
func readToken(ask: Bool, label: String) -> String? {
    if let token = option("token") { return token }
    if flag("token-stdin") {
        return readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard ask, isatty(STDIN_FILENO) != 0, let raw = getpass("\(label): ") else { return nil }
    let token = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
    return token.isEmpty ? nil : token
}

func parseKind(_ text: String) -> ToolKind {
    let aliases: [String: ToolKind] = [
        "claude-code": .claude, "anthropic": .claude,
        "codex-cli": .codex, "openai": .codex,
        "github-copilot": .copilot, "gh": .copilot,
        "logs": .customLogs, "log-folder": .customLogs, "custom-logs": .customLogs,
        "url": .customEndpoint, "endpoint": .customEndpoint, "custom": .customEndpoint, "custom-endpoint": .customEndpoint,
    ]
    let key = text.lowercased()
    if let kind = ToolKind(rawValue: key) ?? ToolKind.allCases.first(where: { $0.rawValue.lowercased() == key }) ?? aliases[key] {
        return kind
    }
    fail("unknown tool \"\(text)\". Run `brim kinds` to see what you can connect.")
}

/// Applies the kind-specific flags shared by `add` and `set`.
func applyOptions(to connection: inout Connection) {
    typealias O = Connection.Option
    let mapping: [(flag: String, key: String)] = [
        ("path", O.path), ("config", O.configDir), ("format", O.format), ("url", O.url), ("header", O.authHeader), ("prefix", O.authPrefix),
        ("used", O.usedPath), ("limit", O.limitPath), ("plan-path", O.planPath), ("reset", O.resetPath), ("label", O.label),
        ("github-user", O.githubLogin),
    ]
    for (flagName, key) in mapping {
        if let value = option(flagName) { connection.options[key] = value }
    }
    if let format = connection.options[O.format], LogFormat(rawValue: format) == nil {
        fail("--format must be claude or codex")
    }
    if let plan = option("plan") { connection.planID = validatedPlan(plan, for: connection.kind) }
    if let name = option("name") { connection.name = name }
}

func validatedPlan(_ plan: String, for kind: ToolKind) -> String {
    if plan == Plans.automatic { return plan }
    guard Plans.options(for: kind).contains(where: { $0.id == plan }) else {
        let ids = ([Plans.automatic] + Plans.options(for: kind).map(\.id)).joined(separator: ", ")
        fail("unknown plan \"\(plan)\" for \(kind.displayName). Choose one of: \(ids)")
    }
    return plan
}

// MARK: - Usage

struct ToolReport: Encodable {
    let id: String
    let name: String
    let kind: String
    var plan: String?
    let todayTokens: Int64?
    var windows: [Window]
    let error: String?
    /// The signed-in account, as the tool reports it. Printed only; never saved.
    var account: String? = nil
    /// Set when `windows` is an older reading (an idle Claude account whose sign-in expired).
    var limitsAsOf: Date? = nil
    var limitsNote: String? = nil
    var tokens: Tokens? = nil
    var models: [Model]? = nil

    struct Window: Encodable {
        let label: String
        let usedPercent: Double
        let resetsAt: Date?
        let detail: String?
        var model: String? = nil
    }

    struct Counts: Encodable {
        let input, output, cacheWrite, cacheRead, total: Int64
        init(_ t: TokenCounts) { (input, output, cacheWrite, cacheRead, total) = (t.input, t.output, t.cacheWrite, t.cacheRead, t.total) }
    }

    struct Tokens: Encodable {
        let today, last5Hours, week, month: Counts
    }

    struct Model: Encodable {
        let model: String
        let today, week: Counts
    }
}

/// Live Claude limits per connection ID, from Anthropic (see `ClaudeUsageFetcher`).
func fetchClaudeLimits(_ connections: [Connection]) async -> [String: (account: ClaudeAccount, result: Result<[PlanWindow], Error>)] {
    await withTaskGroup(of: (String, ClaudeAccount, Result<[PlanWindow], Error>).self) { group in
        for connection in connections where connection.kind == .claude {
            guard let dir = connection.claudeConfigDir() else { continue }
            group.addTask {
                let account = ClaudeAccounts.account(configDir: dir)
                do { return (connection.id, account, .success(try await ClaudeUsageFetcher.fetch(account))) }
                catch { return (connection.id, account, .failure(error)) }
            }
        }
        var results: [String: (account: ClaudeAccount, result: Result<[PlanWindow], Error>)] = [:]
        for await (id, account, result) in group { results[id] = (account, result) }
        return results
    }
}

typealias AccountResult = (id: String, result: Result<AccountUsage, Error>)

/// Reads logs and fetches account usage for every connected connection.
func collectReports() async -> [ToolReport] {
    let active = file.connections.filter(\.isEnabled)

    let engine = UsageEngine(historyDays: 30)
    engine.configure(active.compactMap { c in c.logSource().map { (id: c.id, source: $0) } })
    let statusLine = ClaudeStatusLineSetup(supportDirectory: ClaudeStatusLineSetup.defaultSupportDirectory,
                                           settingsURL: ClaudeStatusLineSetup.defaultSettingsURL())
    let planWindows = statusLine.planWindows()
    engine.externalPlanWindows = Dictionary(active.filter { $0.kind == .claude && $0.usesDefaultLocation }.map { ($0.id, planWindows) },
                                            uniquingKeysWith: { first, _ in first })
    engine.scan()
    let logs = Dictionary(engine.snapshot().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    let accounts = await withTaskGroup(of: AccountResult.self) { group -> [String: Result<AccountUsage, Error>] in
        for connection in active where connection.kind.source == .account {
            group.addTask {
                do { return (connection.id, .success(try await AccountFetcher.fetch(connection))) }
                catch { return (connection.id, .failure(error)) }
            }
        }
        var results: [String: Result<AccountUsage, Error>] = [:]
        for await (id, result) in group { results[id] = result }
        return results
    }

    let claude = await fetchClaudeLimits(active)
    let cacheURL = ClaudeLimitsCache.defaultURL(supportDirectory: ClaudeStatusLineSetup.defaultSupportDirectory)
    var cache = ClaudeLimitsCache.load(from: cacheURL)
    for entry in claude.values {
        if case .success(let windows) = entry.result { cache.readings[entry.account.key] = .init(windows: windows, fetchedAt: Date()) }
    }
    if claude.values.contains(where: { if case .success = $0.result { return true } else { return false } }) { cache.save(to: cacheURL) }

    return active.map { connection -> ToolReport in
        let plan = Plans.tier(connection.planID, for: connection.kind)?.name
        func windows(_ list: [PlanWindow]) -> [ToolReport.Window] {
            list.map { ToolReport.Window(label: $0.label, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt, detail: $0.detail, model: $0.model) }
        }
        if var tool = logs[connection.id] {
            var report = ToolReport(id: connection.id, name: connection.name, kind: connection.kind.rawValue, plan: plan,
                                    todayTokens: tool.today.total, windows: [],
                                    error: tool.hasData ? nil : "No logs found", account: tool.accountLabel)
            if let entry = claude[connection.id] {
                let live = try? entry.result.get()
                var failure: String?
                if case .failure(let error) = entry.result { failure = error.localizedDescription }
                let resolved = ClaudeLimits.resolve(live: live, statusLine: tool.planWindows, cached: cache.readings[entry.account.key], failure: failure)
                tool.planWindows = resolved.windows
                report.account = entry.account.email
                report.plan = plan ?? entry.account.planLabel
                report.limitsAsOf = resolved.asOf
                report.limitsNote = resolved.note
            }
            report.windows = windows(tool.planWindows)
            report.tokens = .init(today: .init(tool.today), last5Hours: .init(tool.last5Hours), week: .init(tool.week), month: .init(tool.month))
            report.models = tool.models.map { .init(model: $0.model, today: .init($0.today), week: .init($0.week)) }
            return report
        }
        switch accounts[connection.id] {
        case .success(let usage):
            return ToolReport(id: connection.id, name: connection.name, kind: connection.kind.rawValue, plan: plan ?? usage.planName,
                              todayTokens: nil, windows: windows(usage.windows), error: nil, account: usage.accountLabel)
        case .failure(let error):
            return ToolReport(id: connection.id, name: connection.name, kind: connection.kind.rawValue, plan: plan,
                              todayTokens: nil, windows: [], error: error.localizedDescription)
        case nil:
            return ToolReport(id: connection.id, name: connection.name, kind: connection.kind.rawValue, plan: plan,
                              todayTokens: nil, windows: [], error: "Not checked")
        }
    }
}

func bar(_ percent: Double, width: Int = 12) -> String {
    let filled = Int((percent / 100 * Double(width)).rounded())
    let text = String(repeating: "█", count: filled) + String(repeating: "░", count: max(0, width - filled))
    return percent >= 95 ? red(text) : percent >= 80 ? amber(text) : green(text)
}

/// The `/usage`-style block for one log connection: every limit, tokens by kind, tokens per model.
func printFullDetails(_ report: ToolReport) {
    if !report.windows.isEmpty {
        print("  " + dim("PLAN USAGE"))
        for window in report.windows {
            let plan = PlanWindow(label: window.label, usedPercent: window.usedPercent, resetsAt: window.resetsAt, model: window.model)
            let title = ClaudeUsageResponse.title(for: plan).padding(toLength: 20, withPad: " ", startingAt: 0)
            let reset = window.resetsAt.map { dim(Format.reset($0)) } ?? ""
            print("  \(title) \(bar(window.usedPercent)) \(Format.percent(window.usedPercent).leftPad(4)) used  \(reset)")
        }
    }
    if let tokens = report.tokens {
        print("  " + dim(tableHeader("TOKENS", width: 10, columns: ["input", "output", "cache write", "cache read", "total"])))
        for (name, counts) in [("today", tokens.today), ("last 5h", tokens.last5Hours), ("7 days", tokens.week), ("30 days", tokens.month)] {
            let cells = [counts.input, counts.output, counts.cacheWrite, counts.cacheRead].map { Format.tokens($0).leftPad(11) }.joined(separator: " ")
            print("  \(name.padding(toLength: 10, withPad: " ", startingAt: 0))\(cells) \(bold(Format.tokens(counts.total).leftPad(11)))")
        }
    }
    if let models = report.models, !models.isEmpty {
        print("  " + dim(tableHeader("BY MODEL · 7 DAYS", width: 18, columns: ["input", "output", "cache write", "cache read", "total", "today"])))
        for usage in models {
            let w = usage.week
            let cells = [w.input, w.output, w.cacheWrite, w.cacheRead].map { Format.tokens($0).leftPad(11) }.joined(separator: " ")
            let today = usage.today.total == 0 ? "–" : Format.tokens(usage.today.total)
            print("  \(Format.modelName(usage.model).padding(toLength: 18, withPad: " ", startingAt: 0))\(cells) \(bold(Format.tokens(w.total).leftPad(11))) \(dim(today.leftPad(11)))")
        }
    }
}

func tableHeader(_ title: String, width: Int, columns: [String]) -> String {
    title.padding(toLength: width, withPad: " ", startingAt: 0) + columns.map { $0.leftPad(11) }.joined(separator: " ")
}

extension String {
    func leftPad(_ width: Int) -> String { count >= width ? self : String(repeating: " ", count: width - count) + self }
}

func printReports(_ reports: [ToolReport], full: Bool = false, emails: Bool = true) {
    if reports.isEmpty {
        print("Nothing connected. Try: brim add claude")
        return
    }
    let sources = file.connections.filter(\.isEnabled).compactMap { c in c.logSource().map { (id: c.id, source: $0) } }
    let covered = LogSource.coveredIDs(in: sources)
    let tokens = reports.filter { !covered.contains($0.id) }.compactMap(\.todayTokens).reduce(0, +)
    print(bold("Today") + "  \(Format.tokens(tokens)) tokens · \(reports.count) connected")
    for report in reports {
        print("")
        var header = bold(report.name)
        if let plan = report.plan { header += dim("  \(plan)") }
        if let tokens = report.todayTokens {
            header += "  \(Format.tokens(tokens)) tokens today"
        }
        print(header)
        if emails, let account = report.account, !account.isEmpty { print("  " + dim(account)) }
        if let error = report.error { print("  " + amber(error)) }
        let limitsNote = [report.limitsAsOf.map { "as of \(Format.ago($0))" }, report.limitsNote].compactMap { $0 }.joined(separator: " · ")
        if full {
            printFullDetails(report)
            if !limitsNote.isEmpty { print("  " + amber(limitsNote)) }
            continue
        }
        for window in report.windows where window.model == nil {
            let reset = window.resetsAt.map { dim(Format.reset($0)) } ?? ""
            let detail = window.detail.map { dim(" (\($0) used)") } ?? ""
            let label = window.label.padding(toLength: max(12, window.label.count), withPad: " ", startingAt: 0)
            print("  \(label) \(bar(window.usedPercent)) \(Format.percent(window.usedPercent)) used\(detail)  \(reset)")
        }
        if !limitsNote.isEmpty { print("  " + amber(limitsNote)) }
    }
    if !full, reports.contains(where: { $0.kind == ToolKind.claude.rawValue }) {
        print(dim("\nbrim status --full for every limit, tokens by kind and per model"))
    }
}

// MARK: - Commands

func printHelp() {
    print("""
    \(bold("brim")) \(version) — AI usage in your Mac's notch

    \(bold("USAGE"))
      brim [status] [--json]          Usage of every connected tool
      brim status --full              Also every Claude limit (5h, week, per model), tokens by kind and per model
                                      [--no-emails] hides account emails
      brim claude accounts            Claude Code sign-ins on this Mac and which are connected
      brim list                       All connections and whether they're connected
      brim kinds                      Tools you can connect, with their plans
      brim add <tool> [options]       Add and connect a tool (any number, any mix)
      brim connect <name>|--all       Connect a saved connection again [--token T]
      brim disconnect <name>|--all    Stop tracking (keeps settings and token)
      brim remove <name>              Forget a connection and its token
      brim set <name> [options]       Change a connection's options
      brim plan <name> <plan>         Set the plan (or "auto")
      brim claude-limits connect|disconnect|status
                                           Share Claude's 5h / weekly limits with Brim
      brim open                       Open the Brim app

    \(bold("OPTIONS"))  (for add and set)
      --name N           Your label, e.g. "Claude · Work"
      --plan P           A plan ID from `brim kinds`
      --path DIR         Log folder (claude, codex, custom-logs)
      --config DIR       Claude Code config folder, e.g. ~/.claude-personal (claude)
      --new-account      Sign in to another Claude account in a new folder [--label personal] (claude add)
      --format F         claude or codex (custom-logs)
      --url URL          Usage URL (custom)
      --used P --limit P JSON paths to used / limit values, e.g. data.usage (custom)
      --header H --prefix P --label L --plan-path P --reset P   (custom)
      --token T | --token-stdin   Save a token in the Keychain (prompted if needed)

    \(bold("EXAMPLES"))
      brim add claude
      brim add claude --new-account --label personal
      brim add claude --name "Claude · Work" --config ~/.claude-work
      brim add copilot
      brim add copilot --github-user other-login   # another account the GitHub CLI is signed in to
      brim add openrouter            # prompts for the API key
      brim add custom --name Acme --url https://api.acme.dev/usage --used data.used --limit data.limit
      brim disconnect --all

    Connect as many tools as you like. Changes show up in the app within one refresh.
    """)
}

func testConnection(_ connection: Connection) async {
    guard connection.isEnabled else { return }
    if connection.kind.source == .localLogs {
        let found = connection.logSource()?.roots.contains { FileManager.default.fileExists(atPath: $0.path) } ?? false
        print(found ? green("✓ ") + "Found \(connection.kind.displayName) logs." : amber("! ") + "No logs found yet. Use the tool once, or pass --path.")
        if let dir = connection.claudeConfigDir() {
            do {
                let windows = try await ClaudeUsageFetcher.fetch(ClaudeAccounts.account(configDir: dir))
                print(green("✓ ") + "Limits: " + windows.filter { $0.model == nil }.map { "\($0.label) \(Format.used($0))" }.joined(separator: " · "))
            } catch {
                print(amber("! ") + error.localizedDescription)
            }
        }
        return
    }
    do {
        let usage = try await AccountFetcher.fetch(connection)
        let summary = usage.windows.map { "\($0.label) \(Format.used($0))" }.joined(separator: " · ")
        print(green("✓ ") + "Connected" + (usage.planName.map { " · \($0)" } ?? "") + (summary.isEmpty ? "" : " · \(summary)"))
    } catch {
        print(amber("! ") + error.localizedDescription)
    }
}

let command = arguments.first ?? "status"
if !arguments.isEmpty { arguments.removeFirst() }

switch command {
case "status", "usage":
    let json = flag("json")
    let full = flag("full")
    let emails = !flag("no-emails")
    var reports = runBlocking { await collectReports() }
    if !emails { reports = reports.map { var r = $0; r.account = nil; return r } }
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(data: (try? encoder.encode(reports)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]")
    } else {
        printReports(reports, full: full, emails: emails)
    }

case "claude":
    guard arguments.first == "accounts" else { fail("try: brim claude accounts") }
    arguments.removeFirst()
    let emails = !flag("no-emails")
    let accounts = ClaudeAccounts.discover()
    if accounts.isEmpty { print("No Claude Code folders found. Add one with: brim add claude --new-account") }
    for account in accounts {
        let used = file.connections.first { $0.kind == .claude && $0.claudeConfigDir()?.standardizedFileURL == account.configDir.standardizedFileURL }
        let path = account.configDir.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        let who = account.isSignedIn ? "\(account.kindLabel)\(account.planLabel.map { " · \($0)" } ?? "")" : "not signed in"
        print("\(bold(path))  \(who)\(emails ? account.email.map { "  " + dim($0) } ?? "" : "")")
        print("  " + (used.map { green("● ") + "connected as \($0.name)" } ?? dim("○ not connected · brim add claude --config \(path)")))
    }

case "list", "ls":
    if file.connections.isEmpty { print("No connections yet. Try: brim add claude") }
    for connection in file.connections {
        let state = connection.isEnabled ? green("● on ") : dim("○ off")
        let plan = Plans.tier(connection.planID, for: connection.kind)?.name ?? "auto"
        let token = Keychain.has(connection.id) ? dim(" · token saved") : ""
        print("\(state)  \(bold(connection.name))  \(dim(connection.kind.rawValue)) · plan \(plan)\(token)  \(dim(String(connection.id.prefix(8))))")
    }
    print(dim("\n\(file.enabledCount) of \(file.connections.count) connected"))

case "kinds":
    for kind in ToolKind.allCases {
        let experimental = kind.isExperimental ? amber(" (experimental)") : ""
        print("\(bold(kind.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0))) \(kind.blurb)\(experimental)")
        print(dim("                plans: auto, " + Plans.options(for: kind).map(\.id).joined(separator: ", ")))
    }

case "add":
    let kind = parseKind(positional(0, "tool"))
    arguments.removeFirst()
    var newAccount: ClaudeAccount?
    if kind == .claude, flag("new-account") {
        let label = option("label") ?? "personal"
        print("Signing in to a new Claude account with Claude Code. Finish in your browser…")
        let result: Result<ClaudeAccount, Error> = runBlocking {
            do {
                return .success(try await ClaudeAccountSetup.addAccount(label: label) { url in
                    print(dim("If the browser didn't open, visit: \(url.absoluteString)"))
                })
            } catch { return .failure(error) }
        }
        switch result {
        case .success(let account): newAccount = account
        case .failure(let error): fail(error.localizedDescription)
        }
    }
    var connection = file.add(kind)
    if let newAccount { connection.options[Connection.Option.configDir] = newAccount.configDir.path }
    let namedByUser = arguments.contains("--name")
    applyOptions(to: &connection)
    if kind == .claude, !namedByUser, let dir = connection.claudeConfigDir(), !connection.option(Connection.Option.configDir).isEmpty {
        connection.name = ClaudeAccounts.account(configDir: dir).suggestedName
    }
    let needsToken = kind == .openrouter || (kind == .customEndpoint && arguments.contains("--token-stdin"))
    if let token = readToken(ask: needsToken, label: "\(kind.displayName) token") {
        Keychain.save(token, for: connection.id)
    }
    update(connection)
    save()
    print("Added \(bold(connection.name)).")
    runBlocking { [connection] in await testConnection(connection) }

case "connect" where arguments.first == "--all":
    file.connections = file.connections.map { var c = $0; c.isEnabled = true; return c }
    save()
    print("Connected all \(file.connections.count) connections.")

case "connect":
    var connection = find(positional(0, "connection name"))
    arguments.removeFirst()
    if let token = readToken(ask: false, label: "Token") { Keychain.save(token, for: connection.id) }
    if !connection.isEnabled {
        connection.isEnabled = true
        update(connection)
        save()
    }
    print("Connected \(bold(connection.name)).")
    runBlocking { [connection] in await testConnection(connection) }

case "disconnect":
    if flag("all") {
        file.connections = file.connections.map { var c = $0; c.isEnabled = false; return c }
        save()
        print("Disconnected everything. Run `brim connect <name>` to turn one back on.")
    } else {
        var connection = find(positional(0, "connection name (or --all)"))
        connection.isEnabled = false
        update(connection)
        save()
        print("Disconnected \(bold(connection.name)). Its settings and token are kept.")
    }

case "remove", "rm":
    let connection = find(positional(0, "connection name"))
    Keychain.delete(connection.id)
    file.connections.removeAll { $0.id == connection.id }
    save()
    print("Removed \(bold(connection.name)) and its saved token.")

case "set":
    var connection = find(positional(0, "connection name"))
    arguments.removeFirst()
    applyOptions(to: &connection)
    if let token = readToken(ask: false, label: "Token") { Keychain.save(token, for: connection.id) }
    update(connection)
    save()
    print("Updated \(bold(connection.name)).")
    runBlocking { [connection] in await testConnection(connection) }

case "plan":
    var connection = find(positional(0, "connection name"))
    connection.planID = validatedPlan(positional(1, "plan"), for: connection.kind)
    update(connection)
    save()
    print("\(bold(connection.name)) plan: \(Plans.tier(connection.planID, for: connection.kind)?.name ?? "automatic")")

case "claude-limits":
    let setup = ClaudeStatusLineSetup(supportDirectory: ClaudeStatusLineSetup.defaultSupportDirectory,
                                      settingsURL: ClaudeStatusLineSetup.defaultSettingsURL())
    switch arguments.first ?? "status" {
    case "connect":
        do { try setup.connect() } catch { fail(error.localizedDescription) }
        print(green("✓ ") + "Claude Code will share your 5-hour and weekly limits after its next reply. Your existing status line keeps working.")
    case "disconnect":
        do { try setup.disconnect() } catch { fail(error.localizedDescription) }
        print("Disconnected. Your previous status line is back.")
    default:
        switch setup.state() {
        case .connected: print(green("Connected") + (setup.planWindows().isEmpty ? dim(" · waiting for Claude Code's next reply") : ""))
        case .notConnected: print("Not connected. Run: brim claude-limits connect, or click Connect in Brim's Settings.")
        case .unreadable: print(amber("Claude Code's settings.json could not be read."))
        }
    }

case "open":
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-b", "com.brim.app"]
    try? process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 { fail("Brim.app isn't installed. Run the installer, or ./scripts/build-app.sh --install") }

case "version", "--version", "-v":
    print(version)

case "help", "--help", "-h":
    printHelp()

default:
    fail("unknown command \"\(command)\". Run `brim help`.")
}

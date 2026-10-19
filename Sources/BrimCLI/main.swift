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
        ("path", O.path), ("format", O.format), ("url", O.url), ("header", O.authHeader), ("prefix", O.authPrefix),
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
    let plan: String?
    let todayTokens: Int64?
    let windows: [Window]
    let error: String?
    /// The signed-in account, as the tool reports it. Printed only; never saved.
    var account: String? = nil

    struct Window: Encodable {
        let label: String
        let usedPercent: Double
        let resetsAt: Date?
        let detail: String?
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

    return active.map { connection -> ToolReport in
        let plan = Plans.tier(connection.planID, for: connection.kind)?.name
        func windows(_ list: [PlanWindow]) -> [ToolReport.Window] {
            list.map { ToolReport.Window(label: $0.label, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt, detail: $0.detail) }
        }
        if let tool = logs[connection.id] {
            return ToolReport(id: connection.id, name: connection.name, kind: connection.kind.rawValue, plan: plan,
                              todayTokens: tool.today.total, windows: windows(tool.planWindows),
                              error: tool.hasData ? nil : "No logs found", account: tool.accountLabel)
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

func printReports(_ reports: [ToolReport]) {
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
        if let account = report.account, !account.isEmpty { print("  " + dim(account)) }
        if let error = report.error { print("  " + amber(error)) }
        for window in report.windows {
            let reset = window.resetsAt.map { dim(Format.reset($0)) } ?? ""
            let detail = window.detail.map { dim(" (\($0) used)") } ?? ""
            let label = window.label.padding(toLength: max(12, window.label.count), withPad: " ", startingAt: 0)
            print("  \(label) \(bar(window.usedPercent)) \(Format.percent(window.usedPercent)) used\(detail)  \(reset)")
        }
    }
}

// MARK: - Commands

func printHelp() {
    print("""
    \(bold("brim")) \(version) — AI usage in your Mac's notch

    \(bold("USAGE"))
      brim [status] [--json]          Usage of every connected tool
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
      --format F         claude or codex (custom-logs)
      --url URL          Usage URL (custom)
      --used P --limit P JSON paths to used / limit values, e.g. data.usage (custom)
      --header H --prefix P --label L --plan-path P --reset P   (custom)
      --token T | --token-stdin   Save a token in the Keychain (prompted if needed)

    \(bold("EXAMPLES"))
      brim add claude
      brim add claude --name "Claude · Work" --path ~/work/.claude/projects --plan max5
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
    let reports = runBlocking { await collectReports() }
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(data: (try? encoder.encode(reports)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]")
    } else {
        printReports(reports)
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
    var connection = file.add(kind)
    applyOptions(to: &connection)
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

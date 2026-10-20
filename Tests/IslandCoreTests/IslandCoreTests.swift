import Foundation
import XCTest
@testable import IslandCore

final class ClaudeLogParserTests: XCTestCase {
    static func claudeLine(id: String = "msg_1", request: String = "req_1", timestamp: String = "2026-10-18T19:51:03.066Z",
                           model: String = "claude-sonnet-4-5", input: Int = 2, output: Int = 271, write: Int = 16810, read: Int = 45801) -> String {
        """
        {"type":"assistant","requestId":"\(request)","timestamp":"\(timestamp)","cwd":"/Users/me/code/app","sessionId":"s1",\
        "message":{"id":"\(id)","model":"\(model)","role":"assistant","content":[{"type":"text","text":"secret"}],\
        "usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(write),"cache_read_input_tokens":\(read),"output_tokens":\(output)}}}
        """
    }

    func testParsesAssistantUsage() throws {
        let event = try XCTUnwrap(ClaudeLogParser.parse(Self.claudeLine()))
        XCTAssertEqual(event.format, .claude)
        XCTAssertEqual(event.key, "msg_1:req_1")
        XCTAssertEqual(event.model, "claude-sonnet-4-5")
        XCTAssertEqual(event.tokens, TokenCounts(input: 2, output: 271, cacheWrite: 16810, cacheRead: 45801))
        XCTAssertEqual(event.sessionID, "s1")
        XCTAssertEqual(event.project, "app")
    }

    func testSkipsSyntheticAndNonAssistantLines() {
        XCTAssertNil(ClaudeLogParser.parse(Self.claudeLine(model: "<synthetic>")))
        XCTAssertNil(ClaudeLogParser.parse(#"{"type":"user","message":{"role":"user","content":"hi, \"usage\" \"assistant\""}}"#))
        XCTAssertNil(ClaudeLogParser.parse(Self.claudeLine(input: 0, output: 0, write: 0, read: 0)))
        XCTAssertNil(ClaudeLogParser.parse("{not json \"usage\" \"assistant\" ......................"))
    }

    func testStatusLinePlanWindows() {
        let json = #"{"model":{"id":"x"},"rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":1900000000},"seven_day":{"used_percentage":18,"resets_at":1900500000}}}"#
        let windows = ClaudeStatusLine.planWindows(from: Data(json.utf8))
        XCTAssertEqual(windows.map(\.label), ["5h", "Week"])
        XCTAssertEqual(windows.first?.usedPercent, 42.5)
        XCTAssertEqual(windows.first?.resetsAt, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertTrue(ClaudeStatusLine.planWindows(from: Data("{}".utf8)).isEmpty)
    }
}

final class CodexLogParserTests: XCTestCase {
    static let meta = #"{"timestamp":"2026-10-18T10:00:00.000Z","type":"session_meta","payload":{"id":"sess-1","cwd":"/Users/me/code/api"}}"#
    static let turn = #"{"timestamp":"2026-10-18T10:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5-codex","cwd":"/Users/me/code/api"}}"#

    static func tokenCount(total: Int, input: Int, cached: Int, output: Int, time: String = "2026-10-18T10:00:05.000Z") -> String {
        """
        {"timestamp":"\(time)","type":"event_msg","payload":{"type":"token_count",\
        "info":{"total_token_usage":{"total_tokens":\(total)},"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output)}},\
        "rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1900000000},"secondary":{"used_percent":40.0,"window_minutes":10080,"resets_in_seconds":3600}}}}
        """
    }

    func testTokenCountEventsAndRateLimits() throws {
        let parser = CodexLogParser()
        XCTAssertNil(parser.parse(Self.meta))
        XCTAssertNil(parser.parse(Self.turn))

        let event = try XCTUnwrap(parser.parse(Self.tokenCount(total: 1500, input: 1000, cached: 600, output: 500)))
        XCTAssertEqual(event.format, .codex)
        XCTAssertEqual(event.model, "gpt-5-codex")
        XCTAssertEqual(event.sessionID, "sess-1")
        XCTAssertEqual(event.project, "api")
        XCTAssertEqual(event.tokens, TokenCounts(input: 400, output: 500, cacheWrite: 0, cacheRead: 600))

        // Codex re-emits the same cumulative total; it must not count twice.
        XCTAssertNil(parser.parse(Self.tokenCount(total: 1500, input: 1000, cached: 600, output: 500)))

        XCTAssertEqual(parser.primary?.window.label, "5h")
        XCTAssertEqual(parser.primary?.window.usedPercent, 12)
        XCTAssertEqual(parser.secondary?.window.label, "Week")
        XCTAssertEqual(parser.secondary?.window.resetsAt, JSON.date("2026-10-18T11:00:05.000Z"))
    }

    func testUsageRecordsTakePrecedence() throws {
        let parser = CodexLogParser()
        _ = parser.parse(Self.turn)
        let record = #"{"timestamp":"2026-10-18T10:00:03.000Z","type":"token_usage_record","payload":{"response_id":"resp_1","usage":{"input_tokens":200,"cached_input_tokens":50,"output_tokens":30}}}"#
        let event = try XCTUnwrap(parser.parse(record))
        XCTAssertEqual(event.key, "resp_1")
        XCTAssertEqual(event.tokens, TokenCounts(input: 150, output: 30, cacheWrite: 0, cacheRead: 50))
        XCTAssertNil(parser.parse(Self.tokenCount(total: 230, input: 200, cached: 50, output: 30)))
    }
}

final class UsageEngineTests: XCTestCase {
    private var directory: URL!
    private let now = JSON.date("2026-10-18T20:00:00.000Z")!
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("personal/proj"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("work/proj"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeEngine(_ sources: [(id: String, source: LogSource)]? = nil) -> UsageEngine {
        let fixedNow = now
        let engine = UsageEngine(historyDays: 30, calendar: calendar, now: { fixedNow })
        engine.configure(sources ?? [(id: "personal", source: LogSource(format: .claude, roots: [directory.appendingPathComponent("personal")]))])
        return engine
    }

    func testScansIncrementallyAndDropsDuplicates() throws {
        let file = directory.appendingPathComponent("personal/proj/session.jsonl")
        let line = ClaudeLogParserTests.claudeLine(timestamp: "2026-10-18T19:00:00.000Z")
        // Claude Code repeats the same usage once per content block.
        try (line + "\n" + line + "\n").write(to: file, atomically: true, encoding: .utf8)

        let engine = makeEngine()
        engine.scan()
        var tool = try XCTUnwrap(engine.snapshot().first)
        XCTAssertEqual(tool.id, "personal")
        XCTAssertEqual(tool.logFileCount, 1)
        XCTAssertTrue(tool.hasData)
        XCTAssertEqual(tool.todayRequests, 1)
        XCTAssertEqual(tool.today.total, 2 + 271 + 16810 + 45801)
        XCTAssertEqual(tool.last5Hours.total, tool.today.total)
        XCTAssertEqual(tool.todaySessions, 1)
        XCTAssertEqual(tool.topModel, "claude-sonnet-4-5")

        // Append a second response plus a partially written line.
        let second = ClaudeLogParserTests.claudeLine(id: "msg_2", request: "req_2", timestamp: "2026-10-17T12:00:00.000Z", output: 1000, write: 0, read: 0)
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data((second + "\n" + "{\"type\":\"assis").utf8))
        try handle.close()

        engine.scan()
        tool = try XCTUnwrap(engine.snapshot().first)
        XCTAssertEqual(tool.todayRequests, 1)
        XCTAssertEqual(tool.daily.count, 30)
        XCTAssertEqual(tool.daily[28].tokens.output, 1000) // yesterday
        XCTAssertEqual(tool.week.output, 271 + 1000)
    }

    func testTracksEveryConnectionSeparately() throws {
        try (ClaudeLogParserTests.claudeLine(timestamp: "2026-10-18T19:00:00.000Z") + "\n")
            .write(to: directory.appendingPathComponent("personal/proj/a.jsonl"), atomically: true, encoding: .utf8)
        try (ClaudeLogParserTests.claudeLine(timestamp: "2026-10-18T18:00:00.000Z", output: 5) + "\n")
            .write(to: directory.appendingPathComponent("work/proj/b.jsonl"), atomically: true, encoding: .utf8)

        let engine = makeEngine([
            (id: "personal", source: LogSource(format: .claude, roots: [directory.appendingPathComponent("personal")])),
            (id: "work", source: LogSource(format: .claude, roots: [directory.appendingPathComponent("work")])),
        ])
        engine.scan()
        let tools = engine.snapshot()
        XCTAssertEqual(tools.map(\.id), ["personal", "work"])
        // The same message ID in two accounts counts once in each, not once overall.
        XCTAssertEqual(tools[0].today.output, 271)
        XCTAssertEqual(tools[1].today.output, 5)

        engine.configure([(id: "work", source: LogSource(format: .claude, roots: [directory.appendingPathComponent("work")]))])
        XCTAssertEqual(engine.snapshot().map(\.id), ["work"])
    }

    func testIgnoresEventsOutsideHistoryWindow() throws {
        try (ClaudeLogParserTests.claudeLine(timestamp: "2026-08-01T12:00:00.000Z") + "\n")
            .write(to: directory.appendingPathComponent("personal/proj/old.jsonl"), atomically: true, encoding: .utf8)
        let engine = makeEngine()
        engine.scan()
        XCTAssertEqual(engine.snapshot().first?.month, .zero)
    }

    func testExpiredPlanWindowsAreDropped() {
        let engine = makeEngine()
        engine.externalPlanWindows = ["personal": [
            PlanWindow(label: "5h", usedPercent: 50, resetsAt: now.addingTimeInterval(-60)),
            PlanWindow(label: "Week", usedPercent: 20, resetsAt: now.addingTimeInterval(3600)),
        ]]
        XCTAssertEqual(engine.snapshot().first?.planWindows.map(\.label), ["Week"])
    }
}

final class ConnectionTests: XCTestCase {
    func testAddingAnyNumberOfConnections() {
        var file = ConnectionFile(connections: [])
        for _ in 0..<20 { _ = file.add(.claude) }
        _ = file.add(.copilot)
        XCTAssertEqual(file.connections.count, 21)
        XCTAssertEqual(file.enabledCount, 21)
        XCTAssertEqual(file.connections[1].name, "Claude 2")
        XCTAssertEqual(file.find("claude 2")?.id, file.connections[1].id)
        XCTAssertEqual(file.find(String(file.connections[20].id.prefix(12)))?.kind, .copilot)
    }

    func testStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("connections.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ConnectionStore(url: url)
        XCTAssertEqual(store.load().connections, []) // first run starts empty; the app asks the user
        var file = store.load()
        var custom = file.add(.customEndpoint, name: "Acme")
        custom.options[Connection.Option.url] = "https://api.acme.dev/usage"
        file.connections[file.connections.count - 1] = custom
        try store.save(file)
        XCTAssertEqual(store.load(), file)
    }

    func testDetectsLogToolsWithRecentActivity() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let projects = home.appendingPathComponent(".claude/projects/demo")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let log = projects.appendingPathComponent("session.jsonl")
        try Data("{}\n".utf8).write(to: log)
        let found = ToolDetection.logTools(home: home, environment: [:], now: Date())
        XCTAssertEqual(found.map(\.kind), [.claude])
        XCTAssertTrue(found[0].shouldPreCheck)
        XCTAssertTrue(found[0].detail.contains(".claude/projects"))
    }

    func testLogSources() {
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(Connection(kind: .claude).logSource(home: home, environment: [:])?.roots.first?.path, "/Users/me/.claude/projects")
        let work = Connection(kind: .claude, options: [Connection.Option.path: "~/work/.claude/projects"])
        XCTAssertEqual(work.logSource(home: home, environment: [:])?.roots.map(\.path), ["/Users/me/work/.claude/projects"])
        XCTAssertFalse(work.usesDefaultLocation)
        let folder = Connection(kind: .customLogs, options: [Connection.Option.format: "codex", Connection.Option.path: "/tmp/logs"])
        XCTAssertEqual(folder.logSource(home: home, environment: [:])?.format, .codex)
        XCTAssertNil(Connection(kind: .copilot).logSource(home: home, environment: [:]))
    }

    func testPlanBilling() {
        XCTAssertEqual(Plans.billing(for: Connection(kind: .claude)), .usageWindows)
        XCTAssertEqual(Plans.billing(for: Connection(kind: .claude, planID: "api")), .payAsYouGo)
        XCTAssertEqual(Plans.billing(for: Connection(kind: .copilot)), .allowance)
        XCTAssertNil(Plans.tier("nope", for: .cursor))
    }
}

final class AccountUsageTests: XCTestCase {
    func testCopilotPremiumRequests() throws {
        let json = #"{"copilot_plan":"individual","quota_reset_date":"2026-11-01","quota_snapshots":{"chat":{"unlimited":true,"entitlement":0},"premium_interactions":{"entitlement":300,"remaining":88,"percent_remaining":29.3,"unlimited":false}}}"#
        let usage = try XCTUnwrap(CopilotUsage.parse(Data(json.utf8)))
        XCTAssertEqual(usage.planName, "Pro")
        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.windows[0].label, "Premium")
        XCTAssertEqual(usage.windows[0].detail, "212 / 300")
        XCTAssertEqual(usage.windows[0].usedPercent, 212.0 / 3, accuracy: 0.01)
        XCTAssertNotNil(usage.windows[0].resetsAt)
    }

    func testCopilotNoAccess() {
        let json = #"{"login":"example-user","access_type_sku":"no_access","copilot_plan":"individual","can_signup_for_limited":true}"#
        XCTAssertTrue(CopilotUsage.lacksCopilot(Data(json.utf8)))
        XCTAssertFalse(CopilotUsage.lacksCopilot(Data(#"{"access_type_sku":"free_limited_copilot"}"#.utf8)))
    }

    func testGitHubCLIAccounts() {
        let json = #"""
        {"hosts":{"github.com":[
          {"login":"second-user","active":false,"state":"success","host":"github.com"},
          {"login":"main-user","active":true,"state":"success","host":"github.com"},
          {"login":"expired-user","active":false,"state":"error","host":"github.com"}]}}
        """#
        let accounts = GitHubAccount.parseStatus(Data(json.utf8))
        XCTAssertEqual(accounts.map(\.login), ["main-user", "second-user"])
        XCTAssertEqual(accounts.map(\.isActive), [true, false])
        XCTAssertEqual(GitHubAccount.parseStatus(Data("not json".utf8)), [])
    }

    func testCopilotFreeWithQuotaSnapshots() throws {
        // A real Copilot Free response (2026-10-19), trimmed and with nothing identifying in it.
        let json = #"""
        {"login":"example-user","access_type_sku":"free_limited_copilot","copilot_plan":"individual",
         "quota_reset_date":"2026-11-01","quota_reset_date_utc":"2026-11-01T00:00:00.000Z",
         "quota_snapshots":{
          "chat":{"percent_remaining":93.8,"quota_remaining":187.7,"remaining":187,"entitlement":200,"unlimited":false},
          "completions":{"percent_remaining":100.0,"quota_remaining":2000.0,"remaining":2000,"entitlement":2000,"unlimited":false},
          "premium_interactions":{"percent_remaining":0.0,"quota_remaining":0.0,"remaining":0,"entitlement":0,"unlimited":false,"has_quota":false}}}
        """#
        let usage = try XCTUnwrap(CopilotUsage.parse(Data(json.utf8)))
        XCTAssertEqual(usage.planName, "Free")
        XCTAssertEqual(usage.windows.map(\.label), ["Chat", "Completions"])
        XCTAssertEqual(usage.windows.map(\.detail), ["12 / 200", "0 / 2000"])
        XCTAssertEqual(usage.windows[0].usedPercent, 6.15, accuracy: 0.01)
        XCTAssertNotNil(usage.windows[0].resetsAt)
    }

    func testCopilotFree() throws {
        let json = #"{"copilot_plan":"free","limited_user_reset_date":"2026-11-01","monthly_quotas":{"chat":50,"completions":2000},"limited_user_quotas":{"chat":10,"completions":1500}}"#
        let usage = try XCTUnwrap(CopilotUsage.parse(Data(json.utf8)))
        XCTAssertEqual(usage.planName, "Free")
        XCTAssertEqual(usage.windows.map(\.detail), ["40 / 50", "500 / 2000"])
    }

    func testCursorSummaryAndRequests() throws {
        let summary = #"{"billingCycleEnd":"2026-11-05T00:00:00.000Z","membershipType":"pro","individualUsage":{"plan":{"used":1500,"limit":2000},"onDemand":{"enabled":false}}}"#
        let usage = try XCTUnwrap(CursorUsage.parseSummary(Data(summary.utf8)))
        XCTAssertEqual(usage.planName, "Pro")
        XCTAssertEqual(usage.windows.map(\.usedPercent), [75])

        let requests = #"{"gpt-4":{"numRequests":123,"maxRequestUsage":500},"startOfMonth":"2026-10-05T00:00:00.000Z"}"#
        let legacy = try XCTUnwrap(CursorUsage.parseRequests(Data(requests.utf8), membership: "pro"))
        XCTAssertEqual(legacy.windows.first?.detail, "123 / 500")

        // header.payload.signature, with payload {"sub":"auth0|user_abc"}
        let token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhdXRoMHx1c2VyX2FiYyJ9.sig"
        XCTAssertEqual(CursorUsage.userID(fromAccessToken: token), "user_abc")
    }

    func testCursorPrefersItsOwnPercentages() throws {
        // A real usage-summary response (Pro+, 2026-10-19), with nothing identifying in it.
        let summary = #"""
        {"billingCycleStart":"2026-10-17T11:12:19.000Z","billingCycleEnd":"2026-11-17T11:12:19.000Z",
         "membershipType":"pro_plus","limitType":"user","isUnlimited":false,
         "autoModelSelectedDisplayMessage":"You've used 5% of your included total usage",
         "namedModelSelectedDisplayMessage":"You've used 64% of your included API usage",
         "individualUsage":{"plan":{"enabled":true,"used":6576,"limit":7000,"remaining":424,
           "breakdown":{"included":6576,"bonus":0,"total":6576},
           "autoPercentUsed":2.5633333333333335,"apiPercentUsed":63.63636363636363,"totalPercentUsed":5.239840637450199},
          "onDemand":{"enabled":false,"used":0,"limit":null,"remaining":null}},
         "teamUsage":{}}
        """#
        let usage = try XCTUnwrap(CursorUsage.parseSummary(Data(summary.utf8)))
        XCTAssertEqual(usage.planName, "Pro+")
        // Cursor's page at the same time: "Cursor Models 3% used", "Other Models 64% used".
        XCTAssertEqual(usage.windows.map(\.label), ["Cursor models", "Other models"])
        XCTAssertEqual(Format.used(usage.windows[0]), "3% used")
        XCTAssertEqual(Format.used(usage.windows[1]), "64% used")
        XCTAssertEqual(usage.windows.max(by: { $0.usedPercent < $1.usedPercent })?.label, "Other models")
        XCTAssertNotNil(usage.windows[0].resetsAt)
        XCTAssertEqual(Format.used(PlanWindow(label: "Premium", usedPercent: 70.7, resetsAt: nil, detail: "212 / 300")), "212 / 300 used")
    }

    func testAccountLabelsComeFromTheToolsOwnResponse() throws {
        let copilot = #"{"login":"example-user","copilot_plan":"individual","quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":88,"unlimited":false}}}"#
        let usage = try XCTUnwrap(CopilotUsage.parse(Data(copilot.utf8)))
        XCTAssertEqual(usage.accountLabel, "example-user")
        XCTAssertEqual(usage.windows.first.map(Format.used), "212 / 300 used")

        let windsurf = #"{"userStatus":{"email":"user@example.com","planStatus":{"planInfo":{"planName":"Pro"},"availablePromptCredits":50000,"usedPromptCredits":12500}}}"#
        XCTAssertEqual(WindsurfUsage.parse(Data(windsurf.utf8))?.accountLabel, "user@example.com")

        let snapshot = ToolSnapshot.account(id: "c", kind: .copilot, name: "Copilot", usage: usage, statusMessage: nil)
        XCTAssertEqual(snapshot.accountLabel, "example-user")
    }

    func testWindsurfFindsNestedFields() throws {
        let json = #"{"userStatus":{"planStatus":{"planInfo":{"planName":"Pro"},"availablePromptCredits":"50000","usedPromptCredits":"12500","planEnd":"2026-11-01T00:00:00Z"}}}"#
        let usage = try XCTUnwrap(WindsurfUsage.parse(Data(json.utf8)))
        XCTAssertEqual(usage.planName, "Pro")
        XCTAssertEqual(usage.windows.first?.usedPercent, 25)
    }

    func testEndpointPaths() throws {
        let json = #"{"data":{"label":"my-key","usage":12.5,"limit":50,"items":[{"used":3}]}}"#
        let usage = try XCTUnwrap(EndpointUsage.openRouter.parse(Data(json.utf8)))
        XCTAssertEqual(usage.planName, "my-key")
        XCTAssertEqual(usage.windows.first?.usedPercent, 25)
        XCTAssertEqual(usage.windows.first?.detail, "12.50 / 50")
        XCTAssertEqual(EndpointUsage.value(at: "data.items.0.used", in: try JSONSerialization.jsonObject(with: Data(json.utf8))) as? Int, 3)
        XCTAssertNil(EndpointUsage(usedPath: "nope", limitPath: "").parse(Data(json.utf8)))
    }
}

final class StatusLineSetupTests: XCTestCase {
    func testConnectKeepsExistingStatusLineAndDisconnectRestoresIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsURL = root.appendingPathComponent("claude/settings.json")
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"model":"opus","statusLine":{"type":"command","command":"~/my-line.sh","padding":0}}"#
            .write(to: settingsURL, atomically: true, encoding: .utf8)

        let setup = ClaudeStatusLineSetup(supportDirectory: root.appendingPathComponent("Support Dir"), settingsURL: settingsURL)
        XCTAssertEqual(setup.state(), .notConnected)

        try setup.connect()
        XCTAssertEqual(setup.state(), .connected)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: setup.scriptURL.path))
        var settings = try XCTUnwrap(JSON.object(Data(contentsOf: settingsURL)))
        XCTAssertEqual(settings["model"] as? String, "opus")
        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsURL.appendingPathExtension("brim-backup").path))

        // Connecting twice must not overwrite the saved original with our own entry.
        try setup.connect()

        try setup.disconnect()
        XCTAssertEqual(setup.state(), .notConnected)
        settings = try XCTUnwrap(JSON.object(Data(contentsOf: settingsURL)))
        let statusLine = try XCTUnwrap(settings["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, "~/my-line.sh")
        XCTAssertEqual(settings["model"] as? String, "opus")
    }

    func testConnectCreatesSettingsWhenMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = ClaudeStatusLineSetup(supportDirectory: root.appendingPathComponent("support"), settingsURL: root.appendingPathComponent("claude/settings.json"))
        try setup.connect()
        XCTAssertEqual(setup.state(), .connected)
        try setup.disconnect()
        let settings = try XCTUnwrap(JSON.object(Data(contentsOf: setup.settingsURL)))
        XCTAssertNil(settings["statusLine"])
    }

    func testMovesAIIslandFolderAndRepointsStatusLine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let old = root.appendingPathComponent("AIIsland")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try #"{"connections":[]}"#.write(to: old.appendingPathComponent("connections.json"), atomically: true, encoding: .utf8)
        try "#!/bin/sh".write(to: old.appendingPathComponent("ai-island-statusline.sh"), atomically: true, encoding: .utf8)
        try #"{"type":"command","command":"~/my-line.sh"}"#
            .write(to: old.appendingPathComponent("claude-statusline.previous.json"), atomically: true, encoding: .utf8)
        let settingsURL = root.appendingPathComponent("claude/settings.json")
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"statusLine":{"type":"command","command":"'\#(old.path)/ai-island-statusline.sh'"}}"#
            .write(to: settingsURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(LegacyMigration.moveSupportFolder(in: root))
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        let new = root.appendingPathComponent("Brim")
        XCTAssertTrue(fm.fileExists(atPath: new.appendingPathComponent("connections.json").path))
        XCTAssertFalse(LegacyMigration.moveSupportFolder(in: root))

        let setup = ClaudeStatusLineSetup(supportDirectory: new, settingsURL: settingsURL)
        XCTAssertEqual(setup.state(), .connected)
        XCTAssertTrue(try setup.repairIfMoved())
        XCTAssertFalse(try setup.repairIfMoved())
        let settings = try XCTUnwrap(JSON.object(Data(contentsOf: settingsURL)))
        let command = try XCTUnwrap((settings["statusLine"] as? [String: Any])?["command"] as? String)
        XCTAssertTrue(command.contains(setup.scriptURL.path))
        XCTAssertFalse(fm.fileExists(atPath: new.appendingPathComponent("ai-island-statusline.sh").path))

        try setup.disconnect()
        let restored = try XCTUnwrap(JSON.object(Data(contentsOf: settingsURL)))
        XCTAssertEqual((restored["statusLine"] as? [String: Any])?["command"] as? String, "~/my-line.sh")
    }

    func testMergesIntoExistingBrimFolderWithoutOverwriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let old = root.appendingPathComponent("AIIsland"), new = root.appendingPathComponent("Brim")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try "old".write(to: old.appendingPathComponent("connections.json"), atomically: true, encoding: .utf8)
        try "old".write(to: old.appendingPathComponent("claude-statusline.json"), atomically: true, encoding: .utf8)
        try "new".write(to: new.appendingPathComponent("claude-statusline.json"), atomically: true, encoding: .utf8)

        XCTAssertTrue(LegacyMigration.moveSupportFolder(in: root))
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("connections.json")), "old")
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("claude-statusline.json")), "new")
    }
}

final class FormatTests: XCTestCase {
    func testTokens() {
        XCTAssertEqual(Format.tokens(312), "312")
        XCTAssertEqual(Format.tokens(8_400), "8.4K")
        XCTAssertEqual(Format.tokens(845_000), "845K")
        XCTAssertEqual(Format.tokens(1_240_000), "1.24M")
        XCTAssertEqual(Format.tokens(31_000_000), "31.0M")
    }

    func testCountdownAndModelNames() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(130 * 60), now: now), "2h 10m")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(45 * 60), now: now), "45m")
        XCTAssertEqual(Format.modelName("claude-sonnet-4-5-20250929"), "sonnet-4-5")
    }
}

final class OverlappingLogRootTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("brim-cover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func mkdir(_ relative: String) throws -> String {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func source(_ format: LogFormat, _ paths: String...) -> LogSource {
        LogSource(format: format, roots: paths.map { URL(fileURLWithPath: $0) })
    }

    func testNestedAndDuplicateRootsAreCoveredOnce() throws {
        let projects = try mkdir("Users/me/.claude/projects")
        let core = try mkdir("Users/me/.claude/projects/-Users-me-Core")
        let sibling = try mkdir("Users/me/.claude/projects-other")
        let work = try mkdir("Users/me/work-claude/projects")
        let codex = try mkdir("Users/me/.claude/projects/x")
        let sources: [(id: String, source: LogSource)] = [
            ("core", source(.claude, core)),
            ("main", source(.claude, projects)),
            ("again", source(.claude, projects + "/")),
            ("sibling", source(.claude, sibling)),
            ("codex", source(.codex, codex)),
            ("work", source(.claude, work)),
        ]
        XCTAssertEqual(LogSource.coveredIDs(in: sources), ["core", "again"])
    }

    func testMultiRootSourceIsCoveredOnlyWhenEveryRootIs() throws {
        let a = try mkdir("a/projects")
        _ = try mkdir("a/projects/one")
        let b = try mkdir("b/projects")
        let sources: [(id: String, source: LogSource)] = [
            ("main", source(.claude, a)),
            ("mixed", source(.claude, a + "/one", b)),
        ]
        XCTAssertTrue(LogSource.coveredIDs(in: sources).isEmpty)
    }

    func testMissingOAuthProjectsRootDoesNotCoverOrHideSibling() throws {
        let code = try mkdir("claude-code/projects")
        let phantom = root.appendingPathComponent("oauth-only/projects").path // never created
        let sources: [(id: String, source: LogSource)] = [
            ("code", source(.claude, code)),
            ("oauth", source(.claude, phantom)),
        ]
        XCTAssertTrue(LogSource.coveredIDs(in: sources).isEmpty)
    }

    func testTotalSkipsCoveredConnections() {
        var main = ToolSnapshot(id: "main", kind: .claude, name: "Claude Code")
        main.today = TokenCounts(input: 20, output: 2_119, cacheWrite: 102_000, cacheRead: 635_870)
        var core = ToolSnapshot(id: "core", kind: .claude, name: "Claude · Core")
        core.today = TokenCounts(input: 14, output: 1_300, cacheWrite: 42_000, cacheRead: 549_244)
        let snapshot = UsageSnapshot(tools: [main, core], generatedAt: Date(), coveredIDs: ["core"])
        XCTAssertEqual(snapshot.todayTokens, main.today.total)
        XCTAssertEqual(UsageSnapshot(tools: [main, core], generatedAt: Date()).todayTokens, main.today.total + core.today.total)
    }

    func testTodayTokensIgnoresAccountToolsAndOAuthHeadlineFallsBackToPlan() {
        var claude = ToolSnapshot(id: "claude", kind: .claude, name: "Claude Code")
        claude.today = TokenCounts(input: 10, output: 90)
        var cursor = ToolSnapshot(id: "cursor", kind: .cursor, name: "Cursor")
        cursor.hasData = true
        cursor.planWindows = [PlanWindow(label: "Other models", usedPercent: 100, resetsAt: nil)]
        // Cursor has no token totals; must not change the log sum.
        XCTAssertEqual(
            UsageSnapshot(tools: [claude, cursor], generatedAt: Date()).todayTokens,
            claude.today.total
        )

        var oauth = ToolSnapshot(id: "oauth", kind: .claude, name: "Claude · Work")
        oauth.hasData = true
        oauth.planWindows = [PlanWindow(label: "5h", usedPercent: 31, resetsAt: nil)]
        let planOnly = UsageSnapshot(tools: [oauth, cursor], generatedAt: Date())
        XCTAssertEqual(planOnly.todayTokens, 0)
        XCTAssertEqual(planOnly.usageTodayHeadline, "Cursor · 100% used")
        XCTAssertEqual(
            UsageSnapshot(tools: [claude], generatedAt: Date()).usageTodayHeadline,
            "\(Format.tokens(claude.today.total)) tokens"
        )
    }
}

final class LogPathTests: XCTestCase {
    func testSanitizeRootAcceptsHomeRelativeAndRejectsOutside() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("brim-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("logs"), withIntermediateDirectories: true)

        let ok = try XCTUnwrap(LogPath.sanitizeRoot(home.appendingPathComponent("logs").path, home: home))
        XCTAssertTrue(LogPath.isInside(ok, home: home))

        XCTAssertNil(LogPath.sanitizeRoot("/tmp/brim-outside-\(UUID().uuidString)", home: home))
        XCTAssertNil(LogPath.sanitizeRoot("", home: home))
    }

    func testSanitizeRootRefusesSymlinkEscape() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("brim-home-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("brim-out-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = home.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertNil(LogPath.sanitizeRoot(link.path, home: home))
    }

    func testJsonlFilesSkipSymlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brim-logs-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("brim-secret-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("proj"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try "inside".write(to: root.appendingPathComponent("proj/ok.jsonl"), atomically: true, encoding: .utf8)
        try "secret".write(to: outside.appendingPathComponent("leak.jsonl"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: root.appendingPathComponent("proj/leak.jsonl"),
                                  withDestinationURL: outside.appendingPathComponent("leak.jsonl"))

        let files = UsageEngine.jsonlFiles(under: root)
        XCTAssertEqual(files.map(\.url.lastPathComponent), ["ok.jsonl"])
    }
}

final class StatusLineBridgeHardeningTests: XCTestCase {
    func testBridgeScriptRedactsToRateLimitsOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support")
        let setup = ClaudeStatusLineSetup(supportDirectory: support,
                                          settingsURL: root.appendingPathComponent("claude/settings.json"))
        try setup.connect()
        let script = try String(contentsOf: setup.scriptURL, encoding: .utf8)
        XCTAssertTrue(script.contains("plutil -extract rate_limits"))
        XCTAssertFalse(script.contains("printf '%s' \"$INPUT\" > \"$DIR/claude-statusline.json"))

        let input = #"{"session_id":"secret-session","transcript_path":"/tmp/x","rate_limits":{"five_hour":{"used_percentage":9}}}"#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [setup.scriptURL.path]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let saved = try Data(contentsOf: setup.dataURL)
        let object = try XCTUnwrap(JSON.object(saved))
        XCTAssertEqual(object.keys.sorted(), ["rate_limits"])
        XCTAssertNil(object["session_id"])
        XCTAssertNil(object["transcript_path"])
        let attrs = try FileManager.default.attributesOfItem(atPath: setup.dataURL.path)
        let mode = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue ?? 0, 0o600)
    }
}

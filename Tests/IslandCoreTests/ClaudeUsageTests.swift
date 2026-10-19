import Foundation
import XCTest
@testable import IslandCore

final class ClaudeUsageTests: XCTestCase {
    /// The shape of a real `/api/oauth/usage?at_wall=1&skip_spend=1` answer (2026-10-19), trimmed.
    static let usageResponse = #"""
    {"five_hour":{"utilization":16.0,"resets_at":"2026-10-19T13:49:59.760585+00:00","limit_dollars":null,"used_dollars":null},
     "seven_day":{"utilization":39.0,"resets_at":"2026-10-22T22:59:59.760609+00:00"},
     "seven_day_opus":null,"seven_day_sonnet":null,"extra_usage":null,"spend":{"used":{"amount_minor":0,"currency":"USD"}},
     "limits":[
      {"kind":"session","group":"session","percent":16,"severity":"normal","resets_at":"2026-10-19T13:49:59.760585+00:00","scope":null,"is_active":false},
      {"kind":"weekly_all","group":"weekly","percent":39,"severity":"normal","resets_at":"2026-10-22T22:59:59.760609+00:00","scope":null,"is_active":true},
      {"kind":"weekly_scoped","group":"weekly","percent":0,"severity":"normal","resets_at":"2026-10-22T23:00:00+00:00",
       "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}
     ]}
    """#

    func testParsesUsageLikeSlashUsage() throws {
        let windows = try XCTUnwrap(ClaudeUsageResponse.parse(Data(Self.usageResponse.utf8)))
        XCTAssertEqual(windows.map(\.label), ["5h", "Week", "Fable"])
        XCTAssertEqual(windows.map(\.usedPercent), [16, 39, 0])
        XCTAssertEqual(windows.map(\.model), [nil, nil, "Fable"])
        let reset = try XCTUnwrap(windows[0].resetsAt)
        XCTAssertEqual(reset.timeIntervalSince1970, 1_792_417_799.76, accuracy: 0.01)
        XCTAssertEqual(windows[2].resetsAt, ISO8601DateFormatter().date(from: "2026-10-22T23:00:00Z"))
        XCTAssertEqual(windows.map(ClaudeUsageResponse.title(for:)), ["Current session", "Week · all models", "Week · Fable"])
    }

    func testFallsBackToTopLevelWindows() throws {
        let json = #"{"five_hour":{"utilization":72.5,"resets_at":"2026-10-19T13:50:00Z"},"seven_day":{"utilization":10,"resets_at":null},"seven_day_opus":{"utilization":95,"resets_at":"2026-10-22T23:00:00Z"},"seven_day_sonnet":null}"#
        let windows = try XCTUnwrap(ClaudeUsageResponse.parse(Data(json.utf8)))
        XCTAssertEqual(windows.map(\.label), ["5h", "Week", "Opus"])
        XCTAssertEqual(windows.map(\.usedPercent), [72.5, 10, 95])
        XCTAssertEqual(windows[2].model, "Opus")
        XCTAssertNil(windows[1].resetsAt)
    }

    func testRejectsUnknownAnswers() {
        XCTAssertNil(ClaudeUsageResponse.parse(Data("not json".utf8)))
        XCTAssertNil(ClaudeUsageResponse.parse(Data(#"{"error":{"type":"authentication_error"}}"#.utf8)))
        XCTAssertEqual(ClaudeUsageResponse.parse(Data(#"{"limits":[]}"#.utf8)), [])
    }

    // MARK: Which limits to show

    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func window(_ label: String, _ percent: Double, resetsIn hours: Double) -> PlanWindow {
        PlanWindow(label: label, usedPercent: percent, resetsAt: now.addingTimeInterval(hours * 3_600))
    }

    func testLiveLimitsWin() {
        let cached = ClaudeLimitsCache.Reading(windows: [window("5h", 90, resetsIn: 1)], fetchedAt: now.addingTimeInterval(-600))
        let resolved = ClaudeLimits.resolve(live: [window("5h", 20, resetsIn: 2)], statusLine: [], cached: cached, failure: nil, now: now)
        XCTAssertEqual(resolved.windows.map(\.usedPercent), [20])
        XCTAssertNil(resolved.asOf)
        XCTAssertNil(resolved.note)
    }

    func testOldReadingShownUntilItResets() {
        let fetched = now.addingTimeInterval(-7_200)
        let cached = ClaudeLimitsCache.Reading(windows: [window("5h", 64, resetsIn: -0.5), window("Week", 41, resetsIn: 30)], fetchedAt: fetched)
        let resolved = ClaudeLimits.resolve(live: nil, statusLine: [], cached: cached, failure: "Sign-in expired. Open Claude Code to refresh.", now: now)
        XCTAssertEqual(resolved.windows.map(\.label), ["Week"], "the 5h reading already reset, so it no longer holds")
        XCTAssertEqual(resolved.asOf, fetched)
        XCTAssertEqual(resolved.note, "Sign-in expired. Open Claude Code to refresh.")
    }

    func testNeverGuessesWhenNothingIsKnown() {
        let cached = ClaudeLimitsCache.Reading(windows: [window("Week", 41, resetsIn: -1)], fetchedAt: now.addingTimeInterval(-900_000))
        let resolved = ClaudeLimits.resolve(live: nil, statusLine: [], cached: cached, failure: "Not signed in to Claude Code in this folder.", now: now)
        XCTAssertTrue(resolved.windows.isEmpty)
        XCTAssertNil(resolved.asOf)
        XCTAssertEqual(resolved.note, "Not signed in to Claude Code in this folder.")
    }

    func testStatusLineBeatsAnOldReading() {
        let cached = ClaudeLimitsCache.Reading(windows: [window("5h", 10, resetsIn: 3)], fetchedAt: now.addingTimeInterval(-3_600))
        let resolved = ClaudeLimits.resolve(live: nil, statusLine: [window("5h", 30, resetsIn: 3)], cached: cached, failure: "x", now: now)
        XCTAssertEqual(resolved.windows.map(\.usedPercent), [30])
        XCTAssertNil(resolved.asOf)
    }

    func testCacheRoundTripsWithoutSecrets() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("claude-limits.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let reading = ClaudeLimitsCache.Reading(windows: [PlanWindow(label: "Fable", usedPercent: 12, resetsAt: Date(timeIntervalSince1970: 1_800_000_000), model: "Fable")],
                                                fetchedAt: Date(timeIntervalSince1970: 1_799_999_000))
        ClaudeLimitsCache(readings: ["abc": reading]).save(to: url)
        XCTAssertEqual(ClaudeLimitsCache.load(from: url).readings["abc"], reading)
        let text = try String(contentsOf: url)
        XCTAssertFalse(text.contains("@"))
        XCTAssertTrue(ClaudeLimitsCache.load(from: url.appendingPathExtension("missing")).readings.isEmpty)
    }
}

final class ClaudeAccountTests: XCTestCase {
    var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("brim-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func write(_ json: String, to path: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    func oauth(email: String, type: String, tier: String) -> String {
        #"{"numStartups":3,"oauthAccount":{"accountUuid":"redacted","emailAddress":"\#(email)","organizationType":"\#(type)","userRateLimitTier":"\#(tier)"}}"#
    }

    func testDiscoversEveryConfigFolderAndLabelsIt() throws {
        try write(oauth(email: "work@example.com", type: "claude_team", tier: "default_claude_max_5x"), to: ".claude.json")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/projects"), withIntermediateDirectories: true)
        try write(oauth(email: "me@example.com", type: "claude_max", tier: "default_claude_max_20x"), to: ".claude-personal/.claude.json")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude-unrelated"), withIntermediateDirectories: true)
        try write("{}", to: ".claude-notes.json")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("elsewhere/projects"), withIntermediateDirectories: true)

        let accounts = ClaudeAccounts.discover(home: home, environment: ["CLAUDE_CONFIG_DIR": home.appendingPathComponent("elsewhere").path])
        XCTAssertEqual(accounts.map(\.configDir.lastPathComponent), [".claude", "elsewhere", ".claude-personal"])

        let work = accounts[0]
        XCTAssertTrue(work.isDefault)
        XCTAssertEqual(work.email, "work@example.com")
        XCTAssertEqual(work.kindLabel, "Work")
        XCTAssertEqual(work.suggestedName, "Claude · Work")
        XCTAssertEqual(work.planLabel, "Team")
        XCTAssertEqual(work.keychainServices.first, "Claude Code-credentials")

        XCTAssertFalse(accounts[1].isSignedIn)

        let personal = accounts[2]
        XCTAssertFalse(personal.isDefault)
        XCTAssertEqual(personal.kindLabel, "Personal")
        XCTAssertEqual(personal.planLabel, "Max 20×")
        XCTAssertNotEqual(personal.key, work.key)
    }

    func testKeychainNamesMatchClaudeCode() {
        let personal = ClaudeAccount(configDir: URL(fileURLWithPath: "/Users/me/.claude-personal"), isDefault: false, email: nil, organizationType: nil, rateLimitTier: nil)
        XCTAssertEqual(personal.keychainServices.first, "Claude Code-credentials-ec5d0230")
        let explicitDefault = ClaudeAccount(configDir: URL(fileURLWithPath: "/Users/me/.claude"), isDefault: true, email: nil, organizationType: nil, rateLimitTier: nil)
        XCTAssertEqual(Array(explicitDefault.keychainServices.prefix(2)), ["Claude Code-credentials", "Claude Code-credentials-0bd83d07"])
        XCTAssertEqual(SHA256.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(String(repeating: "a", count: 1_000)).prefix(8), "41edece4")
    }

    func testNewConfigFolderIsUniqueAndNeverTheDefault() throws {
        XCTAssertEqual(ClaudeAccounts.newConfigDir(label: "Personal", home: home).lastPathComponent, ".claude-personal")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude-personal"), withIntermediateDirectories: true)
        XCTAssertEqual(ClaudeAccounts.newConfigDir(label: "personal", home: home).lastPathComponent, ".claude-personal-2")
        XCTAssertEqual(ClaudeAccounts.newConfigDir(label: "  Side  Project! ", home: home).lastPathComponent, ".claude-side-project")
        XCTAssertEqual(ClaudeAccounts.newConfigDir(label: "", home: home).lastPathComponent, ".claude-account")
    }

    func testCredentialsAreParsedButNeverPrinted() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-SECRET","refreshToken":"sk-ant-ort01-SECRET","expiresAt":1800000000000,"scopes":["user:profile"],"subscriptionType":"team"},"mcpOAuth":{}}"#
        let credentials = try XCTUnwrap(ClaudeCredentials.parse(Data(json.utf8)))
        XCTAssertEqual(credentials.accessToken, "sk-ant-oat01-SECRET")
        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(credentials.subscriptionType, "team")
        XCTAssertTrue(credentials.isExpired(now: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertFalse(credentials.isExpired(now: Date(timeIntervalSince1970: 1_799_990_000)))
        XCTAssertFalse("\(credentials)".contains("SECRET"))
        XCTAssertNil(ClaudeCredentials.parse(Data(#"{"mcpOAuth":{}}"#.utf8)))
    }

    func testConnectionFollowsItsConfigFolder() {
        let home = URL(fileURLWithPath: "/Users/me")
        var personal = Connection(kind: .claude, name: "Claude · Personal")
        personal.options[Connection.Option.configDir] = "~/.claude-personal"
        XCTAssertEqual(personal.claudeConfigDir(home: home)?.path, "/Users/me/.claude-personal")
        XCTAssertEqual(personal.logSource(home: home, environment: [:])?.roots.map(\.path), ["/Users/me/.claude-personal/projects"])
        XCTAssertFalse(personal.usesDefaultLocation)

        XCTAssertEqual(Connection(kind: .claude).claudeConfigDir(home: home)?.path, "/Users/me/.claude")

        var project = Connection(kind: .claude, name: "Claude · Core")
        project.options[Connection.Option.path] = "~/.claude/projects/-Users-me-Core"
        XCTAssertEqual(project.claudeConfigDir(home: home)?.path, "/Users/me/.claude")

        var other = Connection(kind: .claude)
        other.options[Connection.Option.path] = "/tmp/some-logs"
        XCTAssertNil(other.claudeConfigDir(home: home))
        XCTAssertNil(Connection(kind: .codex).claudeConfigDir(home: home))
    }
}

final class ModelBreakdownTests: XCTestCase {
    func testTokensPerModelAndKind() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = UsageEngine(historyDays: 30, calendar: calendar, now: { now })
        engine.configure([(id: "c", source: LogSource(format: .claude, roots: []))])
        func event(_ key: String, _ model: String, daysAgo: Double, _ tokens: TokenCounts) -> UsageEvent {
            UsageEvent(format: .claude, key: key, timestamp: now.addingTimeInterval(-daysAgo * 86_400), model: model, tokens: tokens, sessionID: "s", project: nil)
        }
        engine.ingest(event("1", "claude-opus-5", daysAgo: 0, TokenCounts(input: 1, output: 10, cacheWrite: 100, cacheRead: 1_000)), into: "c")
        engine.ingest(event("2", "claude-opus-5", daysAgo: 3, TokenCounts(input: 2, output: 20, cacheWrite: 200, cacheRead: 2_000)), into: "c")
        engine.ingest(event("3", "claude-sonnet-5", daysAgo: 1, TokenCounts(input: 5, output: 5, cacheWrite: 5, cacheRead: 5)), into: "c")
        engine.ingest(event("4", "claude-haiku-4-5", daysAgo: 10, TokenCounts(input: 9, output: 9)), into: "c")
        engine.ingest(event("1", "claude-opus-5", daysAgo: 0, TokenCounts(input: 1, output: 10, cacheWrite: 100, cacheRead: 1_000)), into: "c")

        let models = engine.snapshot()[0].models
        XCTAssertEqual(models.map(\.model), ["claude-opus-5", "claude-sonnet-5"], "older than 7 days and duplicates are left out")
        XCTAssertEqual(models[0].week, TokenCounts(input: 3, output: 30, cacheWrite: 300, cacheRead: 3_000))
        XCTAssertEqual(models[0].today, TokenCounts(input: 1, output: 10, cacheWrite: 100, cacheRead: 1_000))
        XCTAssertEqual(models[1].today, .zero)
        XCTAssertEqual(engine.snapshot()[0].topModel, "claude-opus-5")
    }
}

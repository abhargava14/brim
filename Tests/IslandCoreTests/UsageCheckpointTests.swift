import Foundation
import XCTest
@testable import IslandCore

final class UsageCheckpointTests: XCTestCase {
    private var directory: URL!
    private var checkpointURL: URL!
    private let now = JSON.date("2026-10-18T20:00:00.000Z")!
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        checkpointURL = directory.appendingPathComponent("usage-checkpoint.json")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("personal/proj"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func engine(historyDays: Int) -> UsageEngine {
        let fixedNow = now
        let engine = UsageEngine(historyDays: historyDays, checkpointURL: checkpointURL, calendar: calendar, now: { fixedNow })
        engine.configure([(id: "personal", source: LogSource(format: .claude, roots: [directory.appendingPathComponent("personal")]))])
        return engine
    }

    private func writeLog(name: String, lines: [String], modified: Date? = nil) throws -> URL {
        let file = directory.appendingPathComponent("personal/proj/\(name)")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        }
        return file
    }

    func testPersistsCursorsAcrossEngines() throws {
        let line = ClaudeLogParserTests.claudeLine(timestamp: "2026-10-18T19:00:00.000Z")
        _ = try writeLog(name: "session.jsonl", lines: [line, line])

        let first = engine(historyDays: 7)
        first.scan()
        let firstTotal = try XCTUnwrap(first.snapshot().first).today.total
        XCTAssertGreaterThan(firstTotal, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpointURL.path))

        let second = engine(historyDays: 7)
        second.scan()
        let secondTool = try XCTUnwrap(second.snapshot().first)
        XCTAssertEqual(secondTool.today.total, firstTotal)
        XCTAssertEqual(secondTool.todayRequests, 1)
    }

    func testSkipsCompletedUnchangedFiles() throws {
        let line = ClaudeLogParserTests.claudeLine(timestamp: "2026-10-18T19:00:00.000Z")
        let file = try writeLog(name: "done.jsonl", lines: [line])
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let modified = try XCTUnwrap(attrs[.modificationDate] as? Date)
        let size = try XCTUnwrap(attrs[.size] as? NSNumber).uint64Value

        let first = engine(historyDays: 7)
        first.scan()
        XCTAssertEqual(try XCTUnwrap(first.snapshot().first).todayRequests, 1)

        // Second engine loads checkpoint; completed file should not be re-opened for parse.
        // Append would bump size — leave unchanged and confirm totals stay stable after another scan.
        let second = engine(historyDays: 7)
        second.scan()
        second.scan()
        XCTAssertEqual(try XCTUnwrap(second.snapshot().first).todayRequests, 1)

        let checkpoint = try XCTUnwrap(UsageCheckpoint.load(from: checkpointURL))
        let files = try XCTUnwrap(checkpoint.connections["personal"]?.files)
        let stored = try XCTUnwrap(files.values.first { $0.size == size } ?? files[file.path] ?? files[file.standardizedFileURL.path])
        XCTAssertEqual(stored.offset, size)
        XCTAssertEqual(stored.size, size)
        XCTAssertEqual(stored.modifiedSeconds, Int64(modified.timeIntervalSince1970.rounded(.down)))
    }

    func testPrunesSeenKeysAndPastSessionUsage() throws {
        let fixedNow = now
        let engine = UsageEngine(historyDays: 30, checkpointURL: nil, calendar: calendar, now: { fixedNow })
        engine.configure([(id: "personal", source: LogSource(format: .claude, roots: []))])

        // Today
        engine.ingest(UsageEvent(format: .claude, key: "today-1", timestamp: now.addingTimeInterval(-60),
                                 model: "m", tokens: TokenCounts(input: 1, output: 1), sessionID: "s-today", project: "p"), into: "personal")
        // Yesterday — session detail should be pruned after prune()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        engine.ingest(UsageEvent(format: .claude, key: "y-1", timestamp: yesterday,
                                 model: "m", tokens: TokenCounts(input: 2, output: 2), sessionID: "s-y", project: "p"), into: "personal")
        // Older than 30-day retention — keys and day should disappear
        let ancient = calendar.date(byAdding: .day, value: -40, to: now)!
        engine.ingest(UsageEvent(format: .claude, key: "old-1", timestamp: ancient,
                                 model: "m", tokens: TokenCounts(input: 9, output: 9), sessionID: "s-old", project: "p"), into: "personal")

        // Ancient is rejected at ingest by cutoff; seed it via a temporary wider window then prune.
        engine.setHistoryDays(60)
        engine.ingest(UsageEvent(format: .claude, key: "old-1", timestamp: ancient,
                                 model: "m", tokens: TokenCounts(input: 9, output: 9), sessionID: "s-old", project: "p"), into: "personal")
        XCTAssertGreaterThanOrEqual(engine.retainedSeenKeyCount, 3)

        engine.setHistoryDays(30)
        engine.prune()
        XCTAssertEqual(engine.pastDaySessionUsageCount, 0)
        // old-1 must be gone; today + yesterday remain
        XCTAssertEqual(engine.retainedSeenKeyCount, 2)
        let tool = try XCTUnwrap(engine.snapshot().first)
        XCTAssertEqual(tool.sessions.count, 1)
        XCTAssertEqual(tool.sessions.first?.id, "s-today")
        XCTAssertEqual(tool.daily[28].tokens.output, 2) // yesterday in a 30-day series ending today
    }

    func testCLIHistoryDayConstants() {
        XCTAssertEqual(UsageEngine.compactHistoryDays, 1)
        XCTAssertEqual(UsageEngine.cliHistoryDays, 7)
        XCTAssertEqual(UsageEngine.fullHistoryDays, 30)
    }

    func testCompactScanDoesNotWipeWiderCheckpointDays() throws {
        let today = ClaudeLogParserTests.claudeLine(id: "msg_t", request: "req_t", timestamp: "2026-10-18T19:00:00.000Z", output: 10)
        let yesterday = ClaudeLogParserTests.claudeLine(id: "msg_y", request: "req_y", timestamp: "2026-10-17T12:00:00.000Z", output: 20)
        _ = try writeLog(name: "hist.jsonl", lines: [today, yesterday])

        let full = engine(historyDays: 30)
        full.scan()
        XCTAssertEqual(try XCTUnwrap(full.snapshot().first).daily[28].tokens.output, 20)

        let compact = engine(historyDays: 1)
        compact.scan()
        // Snapshot is today-only, but disk checkpoint must still carry yesterday.
        XCTAssertEqual(try XCTUnwrap(compact.snapshot().first).daily.count, 1)
        let checkpoint = try XCTUnwrap(UsageCheckpoint.load(from: checkpointURL))
        XCTAssertNotNil(checkpoint.connections["personal"]?.days["20261017"])
        XCTAssertEqual(checkpoint.connections["personal"]?.days["20261017"]?.tokens.output, 20)
    }

    func testTruncateInvalidatesCursor() throws {
        let line = ClaudeLogParserTests.claudeLine(timestamp: "2026-10-18T19:00:00.000Z")
        let file = try writeLog(name: "trunc.jsonl", lines: [line, line, line])
        let first = engine(historyDays: 7)
        first.scan()
        XCTAssertEqual(try XCTUnwrap(first.snapshot().first).todayRequests, 1)
        XCTAssertEqual(try XCTUnwrap(first.snapshot().first).today.output, 271)

        // Shorter replacement so size < stored offset forces a full connection rescan.
        let replacement = ClaudeLogParserTests.claudeLine(id: "msg_new", request: "req_new", timestamp: "2026-10-18T19:30:00.000Z", output: 50)
        try (replacement + "\n").write(to: file, atomically: true, encoding: .utf8)

        let second = engine(historyDays: 7)
        second.scan()
        let tool = try XCTUnwrap(second.snapshot().first)
        XCTAssertEqual(tool.todayRequests, 1)
        XCTAssertEqual(tool.today.output, 50)
    }
}

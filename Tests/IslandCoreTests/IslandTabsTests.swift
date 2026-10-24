import Foundation
import XCTest
@testable import IslandCore

final class TabLayoutTests: XCTestCase {
    func testStandardShowsDefaultTabsAndHidesTheRest() {
        let layout = TabLayout.standard
        XCTAssertEqual(layout.visible, TabID.defaultVisible)
        XCTAssertEqual(Set(layout.more), Set(TabID.allCases).subtracting(TabID.defaultVisible))
        XCTAssertEqual(layout.order.count, TabID.allCases.count)
    }

    func testRestoreDropsUnknownAndAddsNewTabsHidden() {
        let layout = TabLayout(savedOrder: ["ai", "bogus", "home", "ai"], savedHidden: ["home"])
        XCTAssertEqual(Array(layout.order.prefix(2)), [.ai, .home])
        XCTAssertEqual(layout.visible, [.ai])
        XCTAssertTrue(layout.hidden.contains(.units))
        XCTAssertEqual(layout.order.count, TabID.allCases.count)
    }

    func testRestoreNeverLeavesTheBarEmpty() {
        let all = TabID.allCases.map(\.rawValue)
        let layout = TabLayout(savedOrder: all, savedHidden: all)
        XCTAssertEqual(layout.visible, [.home])
    }

    func testEmptySaveIsStandard() {
        XCTAssertEqual(TabLayout(savedOrder: [], savedHidden: []), .standard)
    }

    func testMoveSwapsNeighboursAndStopsAtEdges() {
        var layout = TabLayout.standard
        layout.move(.ai, by: -1)
        XCTAssertEqual(Array(layout.order.prefix(2)), [.ai, .home])
        layout.move(.ai, by: -1)
        XCTAssertEqual(layout.order.first, .ai)
    }

    func testLastVisibleTabCannotBeHidden() {
        var layout = TabLayout(order: [.home, .ai], hidden: [.ai])
        layout.setVisible(.home, false)
        XCTAssertEqual(layout.visible, [.home])
        layout.setVisible(.ai, true)
        layout.setVisible(.home, false)
        XCTAssertEqual(layout.visible, [.ai])
    }
}

final class AccountTagTests: XCTestCase {
    func testSplitReadsTagFromName() {
        XCTAssertEqual(AccountTag.split("Claude · Work").tag, "work")
        XCTAssertEqual(AccountTag.split("Claude · Work").base, "Claude")
        XCTAssertNil(AccountTag.split("Codex").tag)
    }

    func testSetTagUpdatesNameAndOption() {
        var connection = Connection(kind: .claude, name: "Claude · Old")
        connection.setTag("Personal")
        XCTAssertEqual(connection.tag, "personal")
        XCTAssertEqual(connection.name, "Claude · personal")
        connection.setTag(nil)
        XCTAssertNil(connection.tag)
        XCTAssertEqual(connection.name, "Claude")
    }
}

final class QuotaHistoryTests: XCTestCase {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testKeepsTheHighestReadingPerDay() {
        var history = QuotaHistory()
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(history.record("a", percent: 20, at: day, calendar: calendar))
        XCTAssertFalse(history.record("a", percent: 10, at: day, calendar: calendar))
        XCTAssertTrue(history.record("a", percent: 35, at: day, calendar: calendar))
        let series = history.series("a", days: 3, now: day, calendar: calendar)
        XCTAssertEqual(series, [nil, nil, 35])
    }

    func testSeriesIsOldestFirst() {
        var history = QuotaHistory()
        let today = Date(timeIntervalSince1970: 1_800_000_000)
        let yesterday = today.addingTimeInterval(-86_400)
        history.record("a", percent: 5, at: yesterday, calendar: calendar)
        history.record("a", percent: 9, at: today, calendar: calendar)
        XCTAssertEqual(history.series("a", days: 2, now: today, calendar: calendar), [5, 9])
    }

    func testRoundTripsThroughDisk() throws {
        var history = QuotaHistory()
        history.record("a", percent: 42)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        history.save(to: url)
        XCTAssertEqual(QuotaHistory.load(from: url), history)
        try? FileManager.default.removeItem(at: url)
    }
}

final class TokenHistoryTests: XCTestCase {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    func testStreakCountsBackFromTodayOrYesterday() {
        var history = TokenHistory()
        let today = Date(timeIntervalSince1970: 1_800_000_000)
        for back in 1...4 { history.record(100, on: today.addingTimeInterval(Double(-back) * 86_400), calendar: calendar) }
        XCTAssertEqual(history.streak(now: today, calendar: calendar), 4)
        history.record(5, on: today, calendar: calendar)
        XCTAssertEqual(history.streak(now: today, calendar: calendar), 5)
        XCTAssertEqual(history.streak(now: today.addingTimeInterval(3 * 86_400), calendar: calendar), 0)
    }

    func testBestRunAndRecordKeepsMax() {
        var history = TokenHistory()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for day in [0, 1, 2, 5, 6] { history.record(10, on: start.addingTimeInterval(Double(day) * 86_400), calendar: calendar) }
        XCTAssertEqual(history.best(calendar: calendar), 3)
        XCTAssertFalse(history.record(5, on: start, calendar: calendar))
        XCTAssertEqual(history.value(on: start, calendar: calendar), 10)
    }

    func testGridHasWeeksOfSevenAndNoFuture() {
        var history = TokenHistory()
        let today = Date(timeIntervalSince1970: 1_800_000_000)
        history.record(42, on: today, calendar: calendar)
        let grid = history.grid(weeks: 4, now: today, calendar: calendar)
        XCTAssertEqual(grid.count, 4)
        XCTAssertTrue(grid.allSatisfy { $0.count == 7 })
        XCTAssertTrue(grid.last!.contains { $0 == 42 })
        let flat = grid.flatMap { $0 }
        XCTAssertEqual(flat.last { $0 != nil } ?? nil, 42)
    }
}

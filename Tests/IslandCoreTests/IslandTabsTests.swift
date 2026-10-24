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

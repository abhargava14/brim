import Foundation
import XCTest
@testable import IslandCore

final class MomentQueueTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func moment(_ style: IslandEvent.Style, _ name: String = "Claude Code", at time: Date? = nil) -> IslandEvent {
        if style == .connected {
            return .connected(connectionID: name, kind: .claude, name: name, detail: "Pro plan", createdAt: time ?? t0)
        }
        return IslandEvent(connectionID: name, kind: .claude, style: style, title: name, detail: "", createdAt: time ?? t0)
    }

    func testFirstMomentShowsAndOthersWaitInPriorityOrder() {
        var queue = MomentQueue()
        XCTAssertTrue(queue.enqueue(moment(.disconnected, "A"), now: t0))
        XCTAssertFalse(queue.enqueue(moment(.milestone, "B"), now: t0))
        XCTAssertFalse(queue.enqueue(moment(.disconnected, "C"), now: t0))
        XCTAssertFalse(queue.enqueue(moment(.milestone, "D"), now: t0))
        XCTAssertEqual(queue.current?.connectionID, "A")
        // Milestones before disconnected; first come first served within a priority.
        XCTAssertEqual(queue.pending.map(\.connectionID), ["B", "D", "C"])
    }

    func testLimitCutsInAndTheInterruptedMomentComesBackFirst() {
        var queue = MomentQueue()
        queue.enqueue(moment(.milestone, "A"), now: t0)
        queue.enqueue(moment(.milestone, "B"), now: t0)
        XCTAssertTrue(queue.enqueue(moment(.limit, "L"), now: t0.addingTimeInterval(1)))
        XCTAssertEqual(queue.current?.connectionID, "L")
        XCTAssertEqual(queue.timeLeft(now: t0.addingTimeInterval(1)), 8)
        XCTAssertEqual(queue.pending.map(\.connectionID), ["A", "B"])
    }

    func testWarningDoesNotCutInOnALimitOrAnotherWarning() {
        var queue = MomentQueue()
        queue.enqueue(moment(.limit, "L"), now: t0)
        XCTAssertFalse(queue.enqueue(moment(.warning, "W1"), now: t0))
        XCTAssertFalse(queue.enqueue(moment(.limit, "L2"), now: t0))
        XCTAssertEqual(queue.current?.connectionID, "L")
        XCTAssertEqual(queue.pending.map(\.connectionID), ["L2", "W1"])

        var other = MomentQueue()
        other.enqueue(moment(.warning, "W1"), now: t0)
        XCTAssertFalse(other.enqueue(moment(.warning, "W2"), now: t0))
        XCTAssertEqual(other.current?.connectionID, "W1")
    }

    func testMilestoneNeverCutsIn() {
        var queue = MomentQueue()
        queue.enqueue(moment(.disconnected, "A"), now: t0)
        XCTAssertFalse(queue.enqueue(moment(.milestone, "M"), now: t0))
        XCTAssertEqual(queue.current?.connectionID, "A")
    }

    func testConnectedMomentsArrivingTogetherBecomeOne() {
        var queue = MomentQueue()
        queue.enqueue(moment(.connected, "Claude Code"), now: t0)
        let id = queue.current?.id
        XCTAssertTrue(queue.enqueue(moment(.connected, "Cursor"), now: t0.addingTimeInterval(2)))
        XCTAssertEqual(queue.current?.id, id, "keeps its identity so the island doesn't re-animate")
        XCTAssertEqual(queue.current?.title, "2 tools connected")
        XCTAssertEqual(queue.current?.detail, "Claude Code, Cursor")
        XCTAssertEqual(queue.timeLeft(now: t0.addingTimeInterval(2)), 4.5, "the grouped moment gets its full time")
        XCTAssertTrue(queue.pending.isEmpty)
    }

    func testWaitingConnectedMomentsAreGrouped() {
        var queue = MomentQueue()
        queue.enqueue(moment(.limit, "L"), now: t0)
        queue.enqueue(moment(.connected, "Claude Code"), now: t0)
        queue.enqueue(moment(.milestone, "M"), now: t0)
        queue.enqueue(moment(.connected, "Cursor"), now: t0)
        queue.enqueue(moment(.connected, "Copilot"), now: t0)
        XCTAssertEqual(queue.pending.map(\.title), ["M", "3 tools connected"])
        XCTAssertEqual(queue.pending.last?.names, ["Claude Code", "Cursor", "Copilot"])
    }

    func testPausingStopsTheClockAndResumeGivesAMinimum() {
        var queue = MomentQueue()
        queue.enqueue(moment(.warning, "W"), now: t0)
        queue.pause(now: t0.addingTimeInterval(3))
        XCTAssertNil(queue.timeLeft(now: t0.addingTimeInterval(60)), "nothing expires while paused")
        queue.resume(now: t0.addingTimeInterval(60))
        XCTAssertEqual(queue.timeLeft(now: t0.addingTimeInterval(60)), 4)

        queue.pause(now: t0.addingTimeInterval(63.9))
        queue.resume(now: t0.addingTimeInterval(100))
        XCTAssertEqual(queue.timeLeft(now: t0.addingTimeInterval(100)), MomentQueue.minimumOnResume)
    }

    func testMomentAddedWhilePausedWaitsForResume() {
        var queue = MomentQueue()
        queue.pause(now: t0)
        XCTAssertTrue(queue.enqueue(moment(.limit, "L"), now: t0))
        XCTAssertNil(queue.timeLeft(now: t0.addingTimeInterval(30)))
        queue.resume(now: t0.addingTimeInterval(30))
        XCTAssertEqual(queue.timeLeft(now: t0.addingTimeInterval(30)), 8)
    }

    func testRestingBetweenMomentsThenShowNext() {
        var queue = MomentQueue()
        queue.enqueue(moment(.milestone, "A"), now: t0)
        queue.finishCurrent()
        XCTAssertFalse(queue.enqueue(moment(.milestone, "B"), now: t0), "waits for the gap to end")
        XCTAssertNil(queue.current)
        XCTAssertTrue(queue.showNext(now: t0.addingTimeInterval(0.5)))
        XCTAssertEqual(queue.current?.connectionID, "B")
        queue.finishCurrent()
        XCTAssertFalse(queue.showNext(now: t0.addingTimeInterval(6)))
        XCTAssertNil(queue.current)
    }

    func testStaleMomentsAreSkipped() {
        var queue = MomentQueue()
        queue.enqueue(moment(.milestone, "A"), now: t0)
        queue.enqueue(moment(.milestone, "Old", at: t0), now: t0)
        queue.enqueue(moment(.milestone, "New", at: t0.addingTimeInterval(400)), now: t0.addingTimeInterval(400))
        queue.finishCurrent()
        queue.showNext(now: t0.addingTimeInterval(401))
        XCTAssertEqual(queue.current?.connectionID, "New")
    }

    func testDismissMovesOn() {
        var queue = MomentQueue()
        queue.enqueue(moment(.milestone, "A"), now: t0)
        queue.enqueue(moment(.milestone, "B"), now: t0)
        XCTAssertTrue(queue.dismiss(now: t0.addingTimeInterval(1)))
        XCTAssertEqual(queue.current?.connectionID, "B")
        XCTAssertFalse(queue.dismiss(now: t0.addingTimeInterval(2)))
        XCTAssertNil(queue.current)
    }
}

final class LimitAlertMemoryTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testSameWindowAlertsOnceUntilItResets() {
        var memory = LimitAlertMemory()
        let reset = t0.addingTimeInterval(3_600)
        let window = PlanWindow(label: "5h", usedPercent: 81, resetsAt: reset)
        XCTAssertTrue(memory.shouldAnnounce(connectionID: "c", window: window, threshold: 80, now: t0))
        XCTAssertFalse(memory.shouldAnnounce(connectionID: "c", window: window, threshold: 80, now: t0.addingTimeInterval(600)))
        XCTAssertTrue(memory.shouldAnnounce(connectionID: "c", window: window, threshold: 95, now: t0.addingTimeInterval(600)), "a higher threshold is new")
        XCTAssertTrue(memory.shouldAnnounce(connectionID: "other", window: window, threshold: 80, now: t0), "connections are separate")

        let next = PlanWindow(label: "5h", usedPercent: 82, resetsAt: reset.addingTimeInterval(18_000))
        XCTAssertTrue(memory.shouldAnnounce(connectionID: "c", window: next, threshold: 80, now: reset.addingTimeInterval(60)), "after the reset")
    }

    func testWindowWithoutResetTimeRearmsAfterAClearDrop() {
        var memory = LimitAlertMemory()
        let high = PlanWindow(label: "Credits", usedPercent: 81, resetsAt: nil)
        XCTAssertTrue(memory.shouldAnnounce(connectionID: "c", window: high, threshold: 80, now: t0))
        memory.observe(connectionID: "c", window: PlanWindow(label: "Credits", usedPercent: 79, resetsAt: nil))
        XCTAssertFalse(memory.shouldAnnounce(connectionID: "c", window: high, threshold: 80, now: t0), "hovering around 80% stays quiet")
        memory.observe(connectionID: "c", window: PlanWindow(label: "Credits", usedPercent: 10, resetsAt: nil))
        XCTAssertTrue(memory.shouldAnnounce(connectionID: "c", window: high, threshold: 80, now: t0))
    }

    func testForget() {
        var memory = LimitAlertMemory()
        let window = PlanWindow(label: "5h", usedPercent: 81, resetsAt: t0.addingTimeInterval(3_600))
        XCTAssertTrue(memory.shouldAnnounce(connectionID: "c", window: window, threshold: 80, now: t0))
        memory.forget(connectionID: "c")
        XCTAssertTrue(memory.shouldAnnounce(connectionID: "c", window: window, threshold: 80, now: t0))
    }
}

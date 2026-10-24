import Foundation
import XCTest
@testable import IslandCore

final class TimerStateTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testPomodoroPausesAndResumesWithoutLosingTime() {
        var state = TimerState()
        state.togglePomodoro(at: t0)
        XCTAssertEqual(state.pomodoroRemaining(at: t0.addingTimeInterval(60)), 24 * 60)
        state.togglePomodoro(at: t0.addingTimeInterval(60))
        XCTAssertFalse(state.pomodoroRunning)
        XCTAssertEqual(state.pomodoroRemaining(at: t0.addingTimeInterval(600)), 24 * 60)
    }

    func testFourthFocusEarnsALongBreak() {
        var state = TimerState()
        for _ in 0..<3 {
            XCTAssertEqual(state.advancePomodoro(at: t0), .focus)
            XCTAssertEqual(state.phase, .shortBreak)
            state.advancePomodoro(at: t0)
        }
        state.advancePomodoro(at: t0)
        XCTAssertEqual(state.phase, .longBreak)
        XCTAssertEqual(state.sessionsToday, 4)
        XCTAssertEqual(state.pomodoroLeft, 15 * 60)
    }

    func testCountdownRestartsWhenFinished() {
        var state = TimerState()
        state.setCountdown(minutes: 5)
        state.toggleCountdown(at: t0)
        XCTAssertEqual(state.countdownRemaining(at: t0.addingTimeInterval(400)), 0)
        state.toggleCountdown(at: t0.addingTimeInterval(400))
        state.toggleCountdown(at: t0.addingTimeInterval(401))
        XCTAssertEqual(state.countdownRemaining(at: t0.addingTimeInterval(401)), 300)
    }

    func testStopwatchLapsNewestFirst() {
        var state = TimerState()
        state.toggleStopwatch(at: t0)
        state.lap(at: t0.addingTimeInterval(10))
        state.lap(at: t0.addingTimeInterval(25))
        XCTAssertEqual(state.laps, [25, 10])
        state.toggleStopwatch(at: t0.addingTimeInterval(30))
        XCTAssertEqual(state.stopwatchElapsed(at: t0.addingTimeInterval(99)), 30)
    }

    func testGlassesResetOnANewDay() {
        var state = TimerState()
        state.addGlass(3, at: t0)
        XCTAssertEqual(state.glasses, 3)
        state.addGlass(1, at: t0.addingTimeInterval(86_400 * 2))
        XCTAssertEqual(state.glasses, 1)
        state.addGlass(-5, at: t0.addingTimeInterval(86_400 * 2))
        XCTAssertEqual(state.glasses, 0)
    }

    func testClockFormats() {
        XCTAssertEqual(Clock.mmss(1500), "25:00")
        XCTAssertEqual(Clock.mmss(3723), "1:02:03")
        XCTAssertEqual(Clock.tenths(187.45), "03:07.4")
        XCTAssertEqual(Clock.hm(20_880), "5h 48m")
    }
}

final class NotesAndLinksTests: XCTestCase {
    func testNoteSnippetWordsAndSearch() {
        let note = Note(title: "", body: "\nfirst line here\nsecond")
        XCTAssertEqual(note.displayTitle, "Untitled")
        XCTAssertEqual(note.snippet, "first line here")
        XCTAssertEqual(note.wordCount, 4)
        XCTAssertTrue(note.matches("SECOND"))
        XCTAssertFalse(note.matches("third"))
    }

    func testLinkHostAndURLDetection() {
        XCTAssertEqual(SavedLink(title: "x", url: "https://www.github.com/brim", folder: "Work").host, "github.com")
        XCTAssertTrue(Links.looksLikeURL("linear.app"))
        XCTAssertTrue(Links.looksLikeURL("https://x.y/z"))
        XCTAssertFalse(Links.looksLikeURL("swift concurrency"))
        XCTAssertFalse(Links.looksLikeURL("v1.2"))
        XCTAssertEqual(Links.normalized("linear.app"), "https://linear.app")
        XCTAssertEqual(Links.suggestedTitle(for: "github.com/brim"), "Github")
        XCTAssertEqual(Links.searchURL("a b")?.absoluteString, "https://www.google.com/search?q=a%20b")
    }

    func testJSONFileRoundTrip() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = JSONFile<[Note]>("notes.json", directory: dir)
        XCTAssertNil(file.load())
        file.save([Note(title: "a", body: "b")])
        XCTAssertEqual(file.load()?.first?.title, "a")
        try? FileManager.default.removeItem(at: dir)
    }
}

final class UnitsTests: XCTestCase {
    func testParsesCommonForms() throws {
        let a = try XCTUnwrap(UnitConverter.parse("5 km to mi"))
        XCTAssertEqual(a.category, .length)
        XCTAssertEqual(a.to?.symbol, "mi")
        XCTAssertEqual(UnitConverter.convert(a.value, from: a.from, to: a.to!), 3.10686, accuracy: 0.0001)

        let b = try XCTUnwrap(UnitConverter.parse("72f in c"))
        XCTAssertEqual(b.category, .temperature)
        XCTAssertEqual(UnitConverter.convert(b.value, from: b.from, to: b.to!), 22.2222, accuracy: 0.001)

        let c = try XCTUnwrap(UnitConverter.parse("3.5 kg"))
        XCTAssertNil(c.to)
        XCTAssertNil(UnitConverter.parse("hello world"))
        XCTAssertNil(UnitConverter.parse("5 km to kg")?.to)
    }

    func testFormatTrimsDigits() {
        XCTAssertEqual(UnitConverter.format(3.106855961), "3.10686")
        XCTAssertEqual(UnitConverter.format(1200), "1,200")
    }
}

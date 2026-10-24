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

final class SearchEngineTests: XCTestCase {
    let google = SearchEngines.builtIn[0]

    func testKeywordsPickTheEngine() {
        let (engine, terms) = SearchEngines.resolve("yt lofi beats", engines: SearchEngines.builtIn, fallback: google)
        XCTAssertEqual(engine.id, "youtube")
        XCTAssertEqual(terms, "lofi beats")
        XCTAssertEqual(SearchEngines.resolve("!gh brim", engines: SearchEngines.builtIn, fallback: google).engine.id, "github")
    }

    func testUnknownWordsGoToTheDefault() {
        let (engine, terms) = SearchEngines.resolve("swift concurrency", engines: SearchEngines.builtIn, fallback: google)
        XCTAssertEqual(engine.id, "google")
        XCTAssertEqual(terms, "swift concurrency")
        XCTAssertEqual(SearchEngines.resolve("yt", engines: SearchEngines.builtIn, fallback: google).terms, "yt")
    }

    func testURLsEncodeTheWords() {
        XCTAssertEqual(google.url(for: "a&b c")?.absoluteString, "https://www.google.com/search?q=a%26b%20c")
        XCTAssertEqual(SearchEngines.builtIn.first { $0.id == "youtube" }?.url(for: "x")?.absoluteString,
                       "https://www.youtube.com/results?search_query=x")
    }

    func testCustomTemplatesAreChecked() {
        XCTAssertTrue(SearchEngine.isValid("https://example.com/find?q=%s"))
        XCTAssertFalse(SearchEngine.isValid("https://example.com/find"))
        XCTAssertFalse(SearchEngine.isValid("javascript:%s"))
        XCTAssertEqual(Set(SearchEngines.builtIn.map(\.keyword)).count, SearchEngines.builtIn.count)
    }
}

final class WorldClockTests: XCTestCase {
    func testSearchFindsAliasesAndZoneCities() {
        XCTAssertEqual(WorldClocks.search("bengaluru").first?.zone, "Asia/Kolkata")
        XCTAssertEqual(WorldClocks.search("san fran").first?.zone, "America/Los_Angeles")
        XCTAssertEqual(WorldClocks.search("Tokyo").first?.label, "Tokyo")
        XCTAssertTrue(WorldClocks.search("").isEmpty)
    }

    func testOffsetText() {
        XCTAssertEqual(WorldClocks.offsetText(0), "Same time")
        XCTAssertEqual(WorldClocks.offsetText(19_800), "+5h 30m")
        XCTAssertEqual(WorldClocks.offsetText(-28_800), "−8h")
        XCTAssertEqual(WorldClocks.offsetText(1800), "+30m")
    }

    func testDayTextAcrossMidnight() {
        // 2026-10-26 02:00 UTC is still the 25th in Los Angeles.
        let date = Date(timeIntervalSince1970: 1_792_980_000)
        let utc = TimeZone(identifier: "UTC")!, la = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(WorldClocks.dayText(la, base: utc, at: date), "Yesterday")
        XCTAssertEqual(WorldClocks.dayText(utc, base: la, at: date), "Tomorrow")
        XCTAssertEqual(WorldClocks.dayText(utc, base: utc, at: date), "Today")
    }

    func testHours() {
        let utc = TimeZone(identifier: "UTC")!
        // Monday 2026-10-26 10:00 UTC.
        let monday = Date(timeIntervalSince1970: 1_793_008_800)
        XCTAssertEqual(WorldClocks.hours(in: utc, at: monday), .working)
        XCTAssertEqual(WorldClocks.hours(in: utc, at: monday.addingTimeInterval(9 * 3600)), .evening)
        XCTAssertEqual(WorldClocks.hours(in: utc, at: monday.addingTimeInterval(16 * 3600)), .asleep)
    }
}

final class WeatherExtrasTests: XCTestCase {
    func testCompass() {
        XCTAssertEqual(OpenMeteo.compass(0), "N")
        XCTAssertEqual(OpenMeteo.compass(350), "N")
        XCTAssertEqual(OpenMeteo.compass(225), "SW")
        XCTAssertEqual(OpenMeteo.compass(90), "E")
    }

    func testAirQuality() {
        let data = Data(#"{"current":{"time":"2026-10-25T10:00","us_aqi":42.4,"pm2_5":8.1}}"#.utf8)
        XCTAssertEqual(OpenMeteo.parseAirQuality(data), 42)
        XCTAssertEqual(OpenMeteo.airQualityText(42), "Good")
        XCTAssertEqual(OpenMeteo.airQualityText(120), "Poor for some")
        XCTAssertNil(OpenMeteo.parseAirQuality(Data("{}".utf8)))
    }
}

final class ClipTextTests: XCTestCase {
    func testHexColor() {
        XCTAssertNotNil(ClipText.hexColor("#1E90FF"))
        XCTAssertEqual(ClipText.hexColor("#fff")?.red, 1)
        XCTAssertNotNil(ClipText.hexColor("1e90ff"))
        XCTAssertNil(ClipText.hexColor("decade"))
        XCTAssertNil(ClipText.hexColor("123456"))
        XCTAssertNil(ClipText.hexColor("abc"))
    }

    func testEmailAndStats() {
        XCTAssertTrue(ClipText.isEmail("a@b.co"))
        XCTAssertFalse(ClipText.isEmail("@b.co"))
        XCTAssertFalse(ClipText.isEmail("hello world@x.com"))
        XCTAssertEqual(ClipText.stats("one two\nthree"), "13 characters · 3 words · 2 lines")
        XCTAssertEqual(ClipText.stats("a"), "1 character · 1 word")
    }
}

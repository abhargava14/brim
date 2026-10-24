import Foundation
import XCTest
@testable import IslandCore

final class ScreenTimeLogTests: XCTestCase {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testSplitsTimeAcrossHours() {
        var log = ScreenTimeLog()
        // 10:05 UTC; 10 minutes back crosses 10:00.
        let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 10, minute: 5))!
        log.add(seconds: 600, app: "com.apple.dt.Xcode", name: "Xcode", endingAt: end, calendar: calendar)
        let day = log.day(end, calendar: calendar)
        XCTAssertEqual(day.total, 600, accuracy: 0.01)
        XCTAssertEqual(day.hours[10] ?? 0, 300, accuracy: 0.01)
        XCTAssertEqual(day.hours[9] ?? 0, 300, accuracy: 0.01)
        XCTAssertEqual(log.names["com.apple.dt.Xcode"], "Xcode")
    }

    func testTopAppsAndWeek() {
        var log = ScreenTimeLog()
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 15))!
        log.add(seconds: 100, app: "a", name: "A", endingAt: now, calendar: calendar)
        log.add(seconds: 300, app: "b", name: "B", endingAt: now, calendar: calendar)
        XCTAssertEqual(log.topApps([log.day(now, calendar: calendar)]).map(\.name), ["B", "A"])
        let week = log.week(endingOn: now, calendar: calendar)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.last?.day.total ?? 0, 400, accuracy: 0.01)
    }

    func testRoundTripsAsJSON() throws {
        var log = ScreenTimeLog()
        log.add(seconds: 60, app: "a", name: "A", endingAt: Date())
        let data = try JSONEncoder().encode(log)
        XCTAssertEqual(try JSONDecoder().decode(ScreenTimeLog.self, from: data), log)
    }
}

final class OpenMeteoTests: XCTestCase {
    let sample = """
    {"utc_offset_seconds":-25200,
     "current":{"temperature_2m":18.2,"apparent_temperature":17.0,"relative_humidity_2m":71,"weather_code":2,"wind_speed_10m":12.5,"uv_index":3.1,"is_day":1},
     "hourly":{"time":["2026-10-19T20:00","2026-10-19T21:00"],"temperature_2m":[18,17],"weather_code":[2,61],"precipitation_probability":[5,40]},
     "daily":{"time":["2026-10-19","2026-10-20"],"weather_code":[2,61],"temperature_2m_max":[21,17],"temperature_2m_min":[13,12],
              "precipitation_probability_max":[10,80],"sunrise":["2026-10-19T07:20","2026-10-20T07:21"],"sunset":["2026-10-19T18:30","2026-10-20T18:29"]}}
    """

    func testParsesCurrentHoursAndDays() throws {
        let forecast = try XCTUnwrap(OpenMeteo.parse(Data(sample.utf8), place: "San Francisco"))
        XCTAssertEqual(forecast.current.temperature, 18.2)
        XCTAssertEqual(forecast.current.code, 2)
        XCTAssertEqual(forecast.hours.count, 2)
        XCTAssertEqual(forecast.hours[1].code, 61)
        XCTAssertEqual(forecast.days.count, 2)
        XCTAssertEqual(forecast.days[0].high, 21)
        XCTAssertNotNil(forecast.days[0].sunrise)
        XCTAssertEqual(OpenMeteo.describe(2), "Partly cloudy")
        XCTAssertEqual(OpenMeteo.symbol(61), "cloud.rain.fill")
    }

    func testRejectsGarbageAndParsesPlaces() {
        XCTAssertNil(OpenMeteo.parse(Data("{}".utf8), place: ""))
        let places = OpenMeteo.parsePlaces(Data(#"{"results":[{"name":"Paris","latitude":48.85,"longitude":2.35,"admin1":"Île-de-France","country":"France"}]}"#.utf8))
        XCTAssertEqual(places.first?.name, "Paris")
        XCTAssertEqual(places.first?.region, "Île-de-France, France")
        XCTAssertTrue(OpenMeteo.forecastURL(latitude: 1, longitude: 2, fahrenheit: true)!.absoluteString.contains("fahrenheit"))
    }
}

final class MeetingLinkTests: XCTestCase {
    func testFindsVideoLinksOnly() {
        let url = MeetingLink.find(in: [nil, "Room 4", "Agenda https://example.com then https://meet.google.com/abc-defg-hij"])
        XCTAssertEqual(url?.host, "meet.google.com")
        XCTAssertEqual(url.map(MeetingLink.service), "Google Meet")
        XCTAssertNil(MeetingLink.find(in: ["https://example.com"]))
        XCTAssertEqual(MeetingLink.find(in: ["https://us02web.zoom.us/j/123"]).map(MeetingLink.service), "Zoom")
    }
}

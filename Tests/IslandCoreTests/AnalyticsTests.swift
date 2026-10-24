import Foundation
import XCTest
@testable import IslandCore

final class DataFastTests: XCTestCase {
    func testOverviewAcceptsLikelySpellings() {
        var report = AnalyticsReport()
        let json = #"{"status":"success","data":{"visitors":2840,"page_views":3410,"bounce_rate":41.2,"avgSessionDuration":72}}"#
        XCTAssertTrue(DataFast.parseOverview(Data(json.utf8), into: &report))
        XCTAssertEqual(report.visitors, 2840)
        XCTAssertEqual(report.pageviews, 3410)
        XCTAssertEqual(report.bounceRate ?? 0, 0.412, accuracy: 0.0001)
        XCTAssertEqual(report.sessionSeconds, 72)
        XCTAssertFalse(DataFast.parseOverview(Data(#"{"error":{"message":"nope"}}"#.utf8), into: &report))
    }

    func testTimeseriesAndRowsFollowTheDocumentedShape() {
        let series = #"{"status":"success","fields":["visitors"],"interval":"day","data":[{"visitors":3,"timestamp":"2026-05-01"},{"visitors":9,"timestamp":"2026-05-02"}],"totals":{"visitors":12}}"#
        XCTAssertEqual(DataFast.parseTimeseries(Data(series.utf8)), [3, 9])
        XCTAssertEqual(DataFast.parseVisitorCount(Data(series.utf8)), 3)
        let pages = #"{"status":"success","data":[{"hostname":"brim.app","path":"/","visitors":1800,"revenue":0,"payments":0}],"pagination":{"limit":5,"offset":0,"total":1}}"#
        let rows = DataFast.parseRows(Data(pages.utf8), labels: ["path"])
        XCTAssertEqual(rows.first?.label, "/")
        XCTAssertEqual(rows.first?.value, 1800)
        let referrers = #"{"data":[{"referrer":"","visitors":20},{"referrer":"github.com","visitors":12}]}"#
        XCTAssertEqual(DataFast.parseRows(Data(referrers.utf8), labels: ["referrer", "source"]).map(\.label), ["Direct/None", "github.com"])
    }

    func testRealtimeAndURL() {
        XCTAssertEqual(DataFast.parseRealtime(Data(#"{"data":{"visitors":3}}"#.utf8)), 3)
        let range = (Date(timeIntervalSince1970: 1_800_000_000), Date(timeIntervalSince1970: 1_800_000_000))
        let url = DataFast.url("pages", range: range, extra: ["limit": "5"]).absoluteString
        XCTAssertTrue(url.hasPrefix("https://datafa.st/api/v1/analytics/pages?startAt="))
        XCTAssertTrue(url.contains("limit=5"))
    }

    func testRangesCoverWholeDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let week = AnalyticsRange.week.dates(now: now, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.day], from: week.start, to: week.end).day, 6)
        let previous = AnalyticsRange.week.previous(now: now, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.day], from: previous.end, to: week.start).day, 1)
    }
}

final class GoogleAnalyticsTests: XCTestCase {
    func testServiceAccountAndJWT() throws {
        let json = #"{"type":"service_account","client_email":"brim@demo.iam.gserviceaccount.com","private_key":"-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n"}"#
        let account = try XCTUnwrap(GoogleAnalytics.parseServiceAccount(json))
        XCTAssertEqual(account.tokenURI, "https://oauth2.googleapis.com/token")
        let jwt = GoogleAnalytics.unsignedJWT(account: account, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(jwt.split(separator: ".").count, 2)
        XCTAssertFalse(jwt.contains("="))
        XCTAssertEqual(GoogleAnalytics.der(fromPEM: account.privateKeyPEM), Data([0, 0, 0]))
    }

    func testPKCS8Unwrap() {
        // SEQUENCE { INTEGER 0, SEQUENCE { OID rsa, NULL }, OCTET STRING { 01 02 03 } }
        let der = Data([0x30, 0x16, 0x02, 0x01, 0x00, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00, 0x04, 0x03, 0x01, 0x02, 0x03])
        XCTAssertEqual(GoogleAnalytics.pkcs1(fromPKCS8: der), Data([1, 2, 3]))
        XCTAssertNil(GoogleAnalytics.pkcs1(fromPKCS8: Data([0x02, 0x01])))
    }

    func testReportRowsAndURLs() {
        let data = #"{"rows":[{"dimensionValues":[{"value":"/docs"}],"metricValues":[{"value":"44"},{"value":"0.5"}]}]}"#
        let rows = GoogleAnalytics.rows(Data(data.utf8))
        XCTAssertEqual(rows.first?.0, "/docs")
        XCTAssertEqual(rows.first?.1, [44, 0.5])
        XCTAssertEqual(GoogleAnalytics.reportURL(property: "properties/123")?.absoluteString, "https://analyticsdata.googleapis.com/v1beta/properties/123:runReport")
        XCTAssertNil(GoogleAnalytics.reportURL(property: "abc"))
        XCTAssertEqual(GoogleAnalytics.error(Data(#"{"error":{"message":"denied"}}"#.utf8)), "denied")
    }
}

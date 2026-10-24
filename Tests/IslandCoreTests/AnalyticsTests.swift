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

final class AnalyticsProviderTests: XCTestCase {
    func testPlausibleRowsAndSeries() {
        let totals = Data(#"{"results":[{"metrics":[120,340,41.5,63],"dimensions":[]}],"meta":{},"query":{}}"#.utf8)
        XCTAssertEqual(Plausible.rows(totals).first?.metrics, [120, 340, 41.5, 63])
        let series = Data(#"{"results":[{"metrics":[5],"dimensions":["2026-10-24"]}],"meta":{"time_labels":["2026-10-23","2026-10-24","2026-10-25"]}}"#.utf8)
        XCTAssertEqual(Plausible.series(series), [0, 5, 0])
        XCTAssertEqual(Plausible.error(Data(#"{"error":"Invalid site"}"#.utf8)), "Invalid site")
        let body = Plausible.body(site: "brim.app", metrics: ["visitors"], dateRange: "7d", dimensions: ["event:page"], limit: 6)
        let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(json["site_id"] as? String, "brim.app")
        XCTAssertEqual((json["pagination"] as? [String: Any])?["limit"] as? Int, 6)
    }

    func testUmamiStatsBothShapes() {
        var report = AnalyticsReport()
        let newer = Data(#"{"pageviews":300,"visitors":120,"visits":150,"bounces":60,"totaltime":9000,"comparison":{"visitors":100}}"#.utf8)
        XCTAssertTrue(Umami.parseStats(newer, into: &report))
        XCTAssertEqual(report.visitors, 120)
        XCTAssertEqual(report.bounceRate, 0.4)
        XCTAssertEqual(report.sessionSeconds, 60)
        XCTAssertEqual(report.previousVisitors, 100)
        var older = AnalyticsReport()
        let legacy = Data(#"{"pageviews":{"value":30,"prev":20},"visitors":{"value":12,"prev":10},"visits":{"value":15,"prev":9}}"#.utf8)
        XCTAssertTrue(Umami.parseStats(legacy, into: &older))
        XCTAssertEqual(older.visitors, 12)
        XCTAssertEqual(older.previousVisitors, 10)
        XCTAssertEqual(Umami.parseMetrics(Data(#"[{"x":"/","y":9},{"x":"","y":2}]"#.utf8)).map(\.label), ["/", "Direct/None"])
        XCTAssertEqual(Umami.parseSeries(Data(#"{"pageviews":[{"x":"a","y":4}],"sessions":[{"x":"a","y":3}]}"#.utf8)), [3])
        XCTAssertEqual(Umami.parseActive(Data(#"{"visitors":4}"#.utf8)), 4)
    }

    func testFathomStringsParse() {
        var report = AnalyticsReport()
        let totals = Data(#"[{"visits":"150","uniques":"120","pageviews":"300","avg_duration":"64.5","bounce_rate":"0.42"}]"#.utf8)
        XCTAssertTrue(Fathom.parseTotals(totals, into: &report))
        XCTAssertEqual(report.visitors, 120)
        XCTAssertEqual(report.bounceRate, 0.42)
        XCTAssertEqual(Fathom.parseRows(Data(#"[{"pathname":"/docs","uniques":"7"}]"#.utf8), field: "pathname").first?.value, 7)
        XCTAssertEqual(Fathom.parseCurrent(Data(#"{"total":14}"#.utf8)), 14)
        let url = Fathom.aggregationURL(site: "ABC", dates: (Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 0)), aggregates: "uniques")!
        XCTAssertTrue(url.absoluteString.contains("entity_id=ABC"))
    }

    func testCustomHostIsNormalised() {
        XCTAssertEqual(AnalyticsSite(name: "a", provider: .umami, host: "stats.example.com/").customHost, "https://stats.example.com")
        XCTAssertNil(AnalyticsSite(name: "a", provider: .plausible, host: " ").customHost)
    }
}

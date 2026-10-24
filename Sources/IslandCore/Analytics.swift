import Foundation

/// A website whose traffic the Analytics tab shows. Keys live in the Keychain under `id`.
public struct AnalyticsSite: Codable, Equatable, Identifiable, Sendable {
    public enum Provider: String, Codable, CaseIterable, Sendable {
        case datafast
        case google

        public var title: String { self == .datafast ? "DataFast" : "Google Analytics" }
    }

    public var id: String
    public var name: String
    public var provider: Provider
    /// GA4 property ID (Google only).
    public var propertyID: String

    public init(id: String = UUID().uuidString, name: String, provider: Provider, propertyID: String = "") {
        self.id = id
        self.name = name
        self.provider = provider
        self.propertyID = propertyID
    }
}

public enum AnalyticsRange: Int, CaseIterable, Codable, Sendable {
    case today, week, month

    public var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "7 days"
        case .month: return "30 days"
        }
    }

    public var days: Int {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        }
    }

    /// First and last day (inclusive) for this range ending today.
    public func dates(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        let end = calendar.startOfDay(for: now)
        return (calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end, end)
    }

    /// The same length of time just before, for the "vs prior" figure.
    public func previous(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date) {
        let current = dates(now: now, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: -1, to: current.start) ?? current.start
        return (calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end, end)
    }
}

/// What the Analytics tab draws for one site and range.
public struct AnalyticsReport: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable {
        public var label: String
        public var value: Double

        public init(label: String, value: Double) {
            self.label = label
            self.value = value
        }
    }

    public var visitors: Double = 0
    public var pageviews: Double = 0
    /// 0–1.
    public var bounceRate: Double?
    public var sessionSeconds: Double?
    public var previousVisitors: Double?
    public var online: Int?
    public var series: [Double] = []
    public var seriesStart: Date?
    public var pages: [Row] = []
    public var sources: [Row] = []
    public var fetchedAt = Date()

    public init() {}

    /// "↑ 12%" against the prior period, when known.
    public var visitorChange: Int? {
        guard let previous = previousVisitors, previous > 0 else { return nil }
        return Int(((visitors / previous) - 1) * 100)
    }
}

// MARK: - DataFast

/// DataFast's analytics API (Bearer `df_` website key, https://datafa.st/api/v1/analytics/…).
/// Only some responses are documented, so field lookups accept the likely spellings.
public enum DataFast {
    public static let base = URL(string: "https://datafa.st/api/v1/analytics/")!

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        QuotaHistory.key(for: date, calendar: calendar)
    }

    public static func url(_ endpoint: String, range: (start: Date, end: Date), extra: [String: String] = [:]) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "startAt", value: day(range.start)), URLQueryItem(name: "endAt", value: day(range.end)),
                     URLQueryItem(name: "timezone", value: TimeZone.current.identifier)]
        items += extra.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items
        return components.url!
    }

    /// Normalises "bounce_rate", "bounceRate", "Bounce Rate" to "bouncerate".
    static func norm(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    /// The object holding the figures: `data` (or its first item), else the top level.
    static func payload(_ data: Data) -> [String: Any]? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let inner = json["data"] as? [String: Any] { return inner }
        if let list = json["data"] as? [[String: Any]], let first = list.first { return first }
        if let totals = json["totals"] as? [String: Any] { return totals }
        return json
    }

    static func find(_ object: [String: Any], _ names: [String]) -> Double? {
        let wanted = Set(names.map(norm))
        for (key, value) in object where wanted.contains(norm(key)) {
            if let n = number(value) { return n }
        }
        return nil
    }

    public static func parseOverview(_ data: Data, into report: inout AnalyticsReport) -> Bool {
        guard let object = payload(data), let visitors = find(object, ["visitors", "uniqueVisitors", "unique_visitors"]) else { return false }
        report.visitors = visitors
        report.pageviews = find(object, ["pageviews", "pageViews", "page_views", "views"]) ?? 0
        if var bounce = find(object, ["bounceRate", "bounce_rate", "bounce"]) {
            if bounce > 1 { bounce /= 100 }
            report.bounceRate = bounce
        }
        if var seconds = find(object, ["avgSessionDuration", "averageSessionDuration", "avg_session_duration", "sessionDuration", "session_duration", "avgSessionDurationSeconds"]) {
            // Some APIs answer in milliseconds.
            if seconds > 36_000 { seconds /= 1000 }
            report.sessionSeconds = seconds
        }
        return true
    }

    public static func parseVisitorCount(_ data: Data) -> Double? {
        guard let object = payload(data) else { return nil }
        return find(object, ["visitors", "uniqueVisitors", "unique_visitors"])
    }

    public static func parseTimeseries(_ data: Data) -> [Double] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = json["data"] as? [[String: Any]] else { return [] }
        return rows.map { find($0, ["visitors"]) ?? 0 }
    }

    /// Rows for pages ("path") and referrers ("referrer", "source"…), with visitors as the value.
    public static func parseRows(_ data: Data, labels: [String]) -> [AnalyticsReport.Row] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = json["data"] as? [[String: Any]] else { return [] }
        let wanted = labels.map(norm)
        return rows.compactMap { row in
            let label = wanted.lazy.compactMap { key in row.first { norm($0.key) == key }?.value as? String }.first
                ?? row.values.compactMap { $0 as? String }.first
            guard let label else { return nil }
            return AnalyticsReport.Row(label: label.isEmpty ? "Direct/None" : label, value: find(row, ["visitors", "count", "value"]) ?? 0)
        }
    }

    public static func parseRealtime(_ data: Data) -> Int? {
        guard let object = payload(data) else { return nil }
        return find(object, ["visitors", "activeVisitors", "active_visitors", "realtime", "count", "online", "current"]).map { Int($0) }
    }
}

// MARK: - Google Analytics 4

/// GA4 Data API with a service-account key (no app registration needed): sign a JWT, swap it for
/// a token, then `runReport`.
public enum GoogleAnalytics {
    public struct ServiceAccount: Equatable, Sendable {
        public let email: String
        public let privateKeyPEM: String
        public let tokenURI: String
    }

    public static func parseServiceAccount(_ json: String) -> ServiceAccount? {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let email = object["client_email"] as? String,
              let key = object["private_key"] as? String else { return nil }
        return ServiceAccount(email: email, privateKeyPEM: key, tokenURI: object["token_uri"] as? String ?? "https://oauth2.googleapis.com/token")
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// The header and claims, ready to sign: "header.claims".
    public static func unsignedJWT(account: ServiceAccount, now: Date = Date()) -> String {
        let header = #"{"alg":"RS256","typ":"JWT"}"#
        let iat = Int(now.timeIntervalSince1970)
        let claims = """
        {"iss":"\(account.email)","scope":"https://www.googleapis.com/auth/analytics.readonly","aud":"\(account.tokenURI)","iat":\(iat),"exp":\(iat + 3600)}
        """
        return base64URL(Data(header.utf8)) + "." + base64URL(Data(claims.utf8))
    }

    /// DER bytes from a PEM block.
    public static func der(fromPEM pem: String) -> Data? {
        let body = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The PKCS#1 RSA key inside a PKCS#8 "PRIVATE KEY" structure (what Google issues),
    /// since Security's RSA import wants PKCS#1.
    public static func pkcs1(fromPKCS8 der: Data) -> Data? {
        var reader = DERReader(Array(der))
        guard reader.enter(0x30) else { return nil } // PrivateKeyInfo
        guard reader.skip(0x02) else { return nil } // version
        guard reader.skip(0x30) else { return nil } // algorithm
        guard let key = reader.read(0x04) else { return nil } // privateKey OCTET STRING
        return Data(key)
    }

    struct DERReader {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func length() -> Int? {
            guard index < bytes.count else { return nil }
            let first = bytes[index]
            index += 1
            if first < 0x80 { return Int(first) }
            let count = Int(first & 0x7F)
            guard count <= 4, index + count <= bytes.count else { return nil }
            var value = 0
            for _ in 0..<count { value = (value << 8) | Int(bytes[index]); index += 1 }
            return value
        }

        mutating func enter(_ tag: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == tag else { return false }
            index += 1
            return length() != nil
        }

        mutating func read(_ tag: UInt8) -> ArraySlice<UInt8>? {
            guard index < bytes.count, bytes[index] == tag else { return nil }
            index += 1
            guard let count = length(), index + count <= bytes.count else { return nil }
            defer { index += count }
            return bytes[index..<(index + count)]
        }

        mutating func skip(_ tag: UInt8) -> Bool { read(tag) != nil }
    }

    public static func reportURL(property: String, realtime: Bool = false) -> URL? {
        let id = property.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "properties/", with: "")
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "https://analyticsdata.googleapis.com/v1beta/properties/\(id):\(realtime ? "runRealtimeReport" : "runReport")")
    }

    static func date(_ date: Date) -> String { QuotaHistory.key(for: date) }

    public static func body(range: (start: Date, end: Date), metrics: [String], dimension: String? = nil, limit: Int? = nil, orderByMetric: Bool = false) -> Data {
        var object: [String: Any] = [
            "dateRanges": [["startDate": date(range.start), "endDate": date(range.end)]],
            "metrics": metrics.map { ["name": $0] },
        ]
        if let dimension {
            object["dimensions"] = [["name": dimension]]
            object["orderBys"] = orderByMetric
                ? [["metric": ["metricName": metrics[0]], "desc": true]]
                : [["dimension": ["dimensionName": dimension]]]
        }
        if let limit { object["limit"] = limit }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// Rows of (dimension, metric values) from a runReport response.
    public static func rows(_ data: Data) -> [(String, [Double])] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = json["rows"] as? [[String: Any]] else { return [] }
        return rows.map { row in
            let dimension = ((row["dimensionValues"] as? [[String: Any]])?.first?["value"] as? String) ?? ""
            let values = (row["metricValues"] as? [[String: Any]] ?? []).map { Double($0["value"] as? String ?? "") ?? 0 }
            return (dimension, values)
        }
    }

    public static func error(_ data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}

import Combine
import Foundation
import IslandCore
import IslandServices

/// Site analytics from DataFast, Google Analytics 4, Plausible, Umami or Fathom. Keys stay in the
/// Keychain; Brim only reads stats and can't change anything.
@MainActor
final class AnalyticsService: ObservableObject {
    @Published private(set) var sites: [AnalyticsSite] = []
    @Published var selected: String? { didSet { load() } }
    @Published var range: AnalyticsRange = .week { didSet { load() } }
    @Published private(set) var reports: [String: AnalyticsReport] = [:]
    /// Why the last refresh of a site failed; its last numbers stay on screen.
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var loading = false

    private let file = JSONFile<[AnalyticsSite]>("analytics-sites.json", directory: LocalData.directory)
    private var tokens: [String: (token: String, expires: Date)] = [:]
    private var timer: Timer?
    private var watchers = 0

    init() {
        sites = file.load() ?? []
        if AppSettings.isSnapshot { loadSample() }
        selected = sites.first?.id
    }

    var current: AnalyticsSite? { sites.first { $0.id == selected } ?? sites.first }
    var report: AnalyticsReport? { current.flatMap { reports[key($0)] } }

    private func key(_ site: AnalyticsSite) -> String { "\(site.id)|\(range.rawValue)" }

    // MARK: Sites

    /// Adds a site after checking the key works. Returns an error message to show, or nil.
    func add(name: String, provider: AnalyticsSite.Provider, secret: String, propertyID: String, host: String = "") async -> String? {
        let property = propertyID.trimmingCharacters(in: .whitespaces)
        let site = AnalyticsSite(name: name.trimmingCharacters(in: .whitespaces).ifEmpty(provider == .plausible ? property.ifEmpty(provider.title) : provider.title),
                                 provider: provider, propertyID: property, host: provider.selfHostable ? host : nil)
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .google:
            guard GoogleAnalytics.parseServiceAccount(secret) != nil else { return "Paste the whole service-account JSON file." }
            guard GoogleAnalytics.reportURL(property: site.propertyID) != nil else { return "The property ID is the number in GA4 › Admin › Property details." }
        case .datafast:
            guard secret.hasPrefix("df_") else { return "DataFast website keys start with df_. Find yours in Website settings › Developer." }
        case .plausible, .umami, .fathom:
            guard !property.isEmpty else { return provider.siteLabel + " is needed." }
        }
        do {
            _ = try await fetch(site, secret: secret, range: .today)
        } catch {
            return error.localizedDescription
        }
        _ = Keychain.save(secret, for: Self.keychainAccount(site.id))
        sites.append(site)
        save()
        selected = site.id
        return nil
    }

    func remove(_ id: String) {
        Keychain.delete(Self.keychainAccount(id))
        sites.removeAll { $0.id == id }
        reports = reports.filter { !$0.key.hasPrefix(id) }
        errors[id] = nil
        save()
        if selected == id { selected = sites.first?.id }
    }

    func updateKey(_ id: String, secret: String) {
        _ = Keychain.save(secret.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.keychainAccount(id))
        tokens[id] = nil
        errors[id] = nil
        load(force: true)
    }

    static func keychainAccount(_ id: String) -> String { "analytics.\(id)" }

    private func save() {
        guard !AppSettings.isSnapshot else { return }
        file.save(sites)
    }

    // MARK: Refresh

    func watch() {
        watchers += 1
        load()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.load(force: true) }
        }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { timer?.invalidate(); timer = nil }
    }

    func load(force: Bool = false) {
        guard !AppSettings.isSnapshot, !BrimQA.skipCredentials, let site = current else { return }
        if !force, let existing = reports[key(site)], Date().timeIntervalSince(existing.fetchedAt) < 90 { return }
        guard let secret = Keychain.read(Self.keychainAccount(site.id)) else {
            errors[site.id] = "The key for \(site.name) is missing. Add it again in Settings › Connections."
            return
        }
        loading = true
        let range = self.range
        Task {
            do {
                let next = try await fetch(site, secret: secret, range: range)
                reports["\(site.id)|\(range.rawValue)"] = next
                errors[site.id] = nil
            } catch {
                errors[site.id] = error.localizedDescription
            }
            loading = false
        }
    }

    enum FetchError: LocalizedError {
        case revoked(String), service(String)
        var errorDescription: String? {
            switch self {
            case .revoked(let provider): return "\(provider) didn't accept the key. It may have been revoked."
            case .service(let message): return message
            }
        }
    }

    private func fetch(_ site: AnalyticsSite, secret: String, range: AnalyticsRange) async throws -> AnalyticsReport {
        switch site.provider {
        case .datafast: return try await fetchDataFast(secret: secret, range: range)
        case .google: return try await fetchGoogle(site, secret: secret, range: range)
        case .plausible: return try await fetchPlausible(site, secret: secret, range: range)
        case .umami: return try await fetchUmami(site, secret: secret, range: range)
        case .fathom: return try await fetchFathom(site, secret: secret, range: range)
        }
    }

    /// One authorised request; 401/403 mean the key was refused.
    private func request(_ url: URL?, provider: String, headers: [String: String], body: Data? = nil,
                         message: (Data) -> String? = { _ in nil }) async throws -> Data {
        guard let url else { throw FetchError.service("That site doesn't look right.") }
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw FetchError.revoked(provider) }
        guard status == 200 else { throw FetchError.service(message(data) ?? "\(provider) answered with HTTP \(status).") }
        return data
    }

    // Plausible

    private func fetchPlausible(_ site: AnalyticsSite, secret: String, range: AnalyticsRange) async throws -> AnalyticsReport {
        let url = Plausible.queryURL(host: site.customHost)
        let headers = ["Authorization": "Bearer \(secret)"]
        @Sendable func query(_ body: Data) async throws -> Data {
            try await request(url, provider: "Plausible", headers: headers, body: body, message: Plausible.error)
        }
        var report = AnalyticsReport()
        let totals = try await query(Plausible.body(site: site.propertyID, metrics: ["visitors", "pageviews", "bounce_rate", "visit_duration"],
                                                    dateRange: Plausible.dateRange(range)))
        guard let values = Plausible.rows(totals).first?.metrics, values.count >= 4 else {
            throw FetchError.service("Plausible answered in a format Brim doesn't understand yet.")
        }
        report.visitors = values[0]
        report.pageviews = values[1]
        report.bounceRate = values[2] / 100
        report.sessionSeconds = values[3]
        async let previous = try? query(Plausible.body(site: site.propertyID, metrics: ["visitors"], dateRange: Plausible.dateRange(range, previous: true)))
        async let series = try? query(Plausible.body(site: site.propertyID, metrics: ["visitors"], dateRange: Plausible.dateRange(range),
                                                     dimensions: [range == .today ? "time:hour" : "time:day"], timeLabels: true))
        async let pages = try? query(Plausible.body(site: site.propertyID, metrics: ["visitors"], dateRange: Plausible.dateRange(range),
                                                    dimensions: ["event:page"], limit: 6))
        async let sources = try? query(Plausible.body(site: site.propertyID, metrics: ["visitors"], dateRange: Plausible.dateRange(range),
                                                      dimensions: ["visit:source"], limit: 6))
        async let online = try? query(Plausible.body(site: site.propertyID, metrics: ["visitors"], dateRange: Plausible.realtimeRange()))
        if let data = await previous { report.previousVisitors = Plausible.rows(data).first?.metrics.first }
        if let data = await series { report.series = Plausible.series(data) }
        if let data = await pages { report.pages = Plausible.rows(data).map { .init(label: $0.dimensions.first ?? "", value: $0.metrics.first ?? 0) } }
        if let data = await sources {
            report.sources = Plausible.rows(data).map { .init(label: ($0.dimensions.first ?? "").ifEmpty("Direct/None"), value: $0.metrics.first ?? 0) }
        }
        if let data = await online { report.online = Plausible.rows(data).first?.metrics.first.map { Int($0) } }
        report.seriesStart = range.dates().start
        return report
    }

    // Umami

    private func fetchUmami(_ site: AnalyticsSite, secret: String, range: AnalyticsRange) async throws -> AnalyticsReport {
        let host = site.customHost
        let headers = host == nil ? ["x-umami-api-key": secret] : ["Authorization": "Bearer \(secret)"]
        let window = Umami.window(range.dates()), before = Umami.window(range.previous())
        @Sendable func get(_ path: String, _ window: (start: Date, end: Date), _ extra: [String: String] = [:]) async throws -> Data {
            try await request(Umami.url(host: host, website: site.propertyID, path: path, window: window, extra: extra), provider: "Umami", headers: headers)
        }
        var report = AnalyticsReport()
        guard Umami.parseStats(try await get("stats", window), into: &report) else {
            throw FetchError.service("Umami answered in a format Brim doesn't understand yet.")
        }
        let unit = range == .today ? "hour" : "day"
        async let previous = try? get("stats", before)
        async let series = try? get("pageviews", window, ["unit": unit, "timezone": TimeZone.current.identifier])
        async let pages = try? get("metrics", window, ["type": "path", "limit": "6"])
        async let sources = try? get("metrics", window, ["type": "referrer", "limit": "6"])
        async let active = try? request(Umami.activeURL(host: host, website: site.propertyID), provider: "Umami", headers: headers)
        if report.previousVisitors == nil, let data = await previous { report.previousVisitors = Umami.parseVisitors(data) }
        if let data = await series { report.series = Umami.parseSeries(data) }
        if let data = await pages { report.pages = Umami.parseMetrics(data) }
        // Versions before 2.x name the page metric "url".
        if report.pages.isEmpty, let data = try? await get("metrics", window, ["type": "url", "limit": "6"]) { report.pages = Umami.parseMetrics(data) }
        if let data = await sources { report.sources = Umami.parseMetrics(data) }
        if let data = await active { report.online = Umami.parseActive(data) }
        report.seriesStart = window.start
        return report
    }

    // Fathom

    private func fetchFathom(_ site: AnalyticsSite, secret: String, range: AnalyticsRange) async throws -> AnalyticsReport {
        let headers = ["Authorization": "Bearer \(secret)"]
        let dates = range.dates()
        @Sendable func get(_ url: URL?) async throws -> Data { try await request(url, provider: "Fathom", headers: headers) }
        var report = AnalyticsReport()
        let totals = try await get(Fathom.aggregationURL(site: site.propertyID, dates: dates, aggregates: "visits,uniques,pageviews,avg_duration,bounce_rate"))
        guard Fathom.parseTotals(totals, into: &report) else { throw FetchError.service("Fathom answered in a format Brim doesn't understand yet.") }
        async let previous = try? get(Fathom.aggregationURL(site: site.propertyID, dates: range.previous(), aggregates: "uniques"))
        async let series = try? get(Fathom.aggregationURL(site: site.propertyID, dates: dates, aggregates: "uniques",
                                                          grouping: range == .today ? "hour" : "day", sort: "timestamp:asc"))
        async let pages = try? get(Fathom.aggregationURL(site: site.propertyID, dates: dates, aggregates: "uniques", field: "pathname", sort: "uniques:desc", limit: 6))
        async let sources = try? get(Fathom.aggregationURL(site: site.propertyID, dates: dates, aggregates: "uniques", field: "referrer_hostname", sort: "uniques:desc", limit: 6))
        async let current = try? get(Fathom.currentURL(site: site.propertyID))
        if let data = await previous { report.previousVisitors = Fathom.parseUniques(data) }
        if let data = await series { report.series = Fathom.parseSeries(data) }
        if let data = await pages { report.pages = Fathom.parseRows(data, field: "pathname") }
        if let data = await sources { report.sources = Fathom.parseRows(data, field: "referrer_hostname") }
        if let data = await current { report.online = Fathom.parseCurrent(data) }
        report.seriesStart = dates.start
        return report
    }

    // DataFast

    private func dataFast(_ url: URL, key: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw FetchError.revoked("DataFast") }
        guard status == 200 else { throw FetchError.service("DataFast answered with HTTP \(status).") }
        return data
    }

    private func fetchDataFast(secret: String, range: AnalyticsRange) async throws -> AnalyticsReport {
        var report = AnalyticsReport()
        let dates = range.dates()
        let overview = try await dataFast(DataFast.url("overview", range: dates), key: secret)
        guard DataFast.parseOverview(overview, into: &report) else { throw FetchError.service("DataFast answered in a format Brim doesn't understand yet.") }
        async let previous = try? dataFast(DataFast.url("overview", range: range.previous()), key: secret)
        async let series = try? dataFast(DataFast.url("timeseries", range: dates, extra: ["fields": "visitors", "interval": range == .today ? "hour" : "day"]), key: secret)
        async let pages = try? dataFast(DataFast.url("pages", range: dates, extra: ["limit": "6"]), key: secret)
        async let referrers = try? dataFast(DataFast.url("referrers", range: dates, extra: ["limit": "6"]), key: secret)
        async let realtime = try? dataFast(DataFast.base.appendingPathComponent("realtime"), key: secret)
        if let data = await previous { report.previousVisitors = DataFast.parseVisitorCount(data) }
        if let data = await series { report.series = DataFast.parseTimeseries(data) }
        if let data = await pages { report.pages = DataFast.parseRows(data, labels: ["path", "page", "pathname"]) }
        if let data = await referrers { report.sources = DataFast.parseRows(data, labels: ["referrer", "source", "domain", "name"]) }
        if let data = await realtime { report.online = DataFast.parseRealtime(data) }
        report.seriesStart = dates.start
        return report
    }

    // Google Analytics 4

    private func googleToken(_ site: AnalyticsSite, secret: String) async throws -> String {
        if let cached = tokens[site.id], cached.expires > Date() { return cached.token }
        guard let account = GoogleAnalytics.parseServiceAccount(secret) else { throw GoogleSigner.SignError.badKey }
        let fresh = try await GoogleSigner.accessToken(account)
        tokens[site.id] = fresh
        return fresh.token
    }

    private func google(_ site: AnalyticsSite, token: String, body: Data, realtime: Bool = false) async throws -> Data {
        guard let url = GoogleAnalytics.reportURL(property: site.propertyID, realtime: realtime) else { throw FetchError.service("That property ID doesn't look right.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw FetchError.service(GoogleAnalytics.error(data) ?? "Google refused. Add the service account as a Viewer on the property.")
        }
        guard status == 200 else { throw FetchError.service(GoogleAnalytics.error(data) ?? "Google answered with HTTP \(status).") }
        return data
    }

    private func fetchGoogle(_ site: AnalyticsSite, secret: String, range: AnalyticsRange) async throws -> AnalyticsReport {
        let token = try await googleToken(site, secret: secret)
        let dates = range.dates()
        var report = AnalyticsReport()
        let totals = GoogleAnalytics.rows(try await google(site, token: token, body: GoogleAnalytics.body(range: dates, metrics: ["activeUsers", "screenPageViews", "bounceRate", "averageSessionDuration"])))
        if let values = totals.first?.1, values.count >= 4 {
            report.visitors = values[0]
            report.pageviews = values[1]
            report.bounceRate = values[2]
            report.sessionSeconds = values[3]
        }
        async let previous = try? google(site, token: token, body: GoogleAnalytics.body(range: range.previous(), metrics: ["activeUsers"]))
        async let series = try? google(site, token: token, body: GoogleAnalytics.body(range: dates, metrics: ["activeUsers"], dimension: range == .today ? "dateHour" : "date"))
        async let pages = try? google(site, token: token, body: GoogleAnalytics.body(range: dates, metrics: ["activeUsers"], dimension: "pagePath", limit: 6, orderByMetric: true))
        async let sources = try? google(site, token: token, body: GoogleAnalytics.body(range: dates, metrics: ["activeUsers"], dimension: "sessionSource", limit: 6, orderByMetric: true))
        async let realtime = try? google(site, token: token, body: (try? JSONSerialization.data(withJSONObject: ["metrics": [["name": "activeUsers"]]])) ?? Data(), realtime: true)
        if let data = await previous { report.previousVisitors = GoogleAnalytics.rows(data).first?.1.first }
        if let data = await series { report.series = GoogleAnalytics.rows(data).map { $0.1.first ?? 0 } }
        if let data = await pages { report.pages = GoogleAnalytics.rows(data).map { .init(label: $0.0, value: $0.1.first ?? 0) } }
        if let data = await sources { report.sources = GoogleAnalytics.rows(data).map { .init(label: $0.0 == "(direct)" ? "Direct/None" : $0.0, value: $0.1.first ?? 0) } }
        if let data = await realtime { report.online = Int(GoogleAnalytics.rows(data).first?.1.first ?? 0) }
        report.seriesStart = dates.start
        return report
    }

    private func loadSample() {
        let site = AnalyticsSite(id: "sample-site", name: "brim.app", provider: .datafast)
        let docs = AnalyticsSite(id: "sample-docs", name: "docs.brim.app", provider: .plausible, propertyID: "docs.brim.app")
        sites = [site, docs]
        var report = AnalyticsReport()
        report.visitors = 2840
        report.pageviews = 3410
        report.bounceRate = 0.41
        report.sessionSeconds = 72
        report.previousVisitors = 2535
        report.online = 3
        report.series = [312, 388, 441, 520, 498, 402, 279]
        report.seriesStart = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))
        report.pages = [.init(label: "/", value: 1800), .init(label: "/download", value: 511), .init(label: "/docs/setup", value: 256),
                        .init(label: "/changelog", value: 170), .init(label: "/docs/limits", value: 142)]
        report.sources = [.init(label: "GitHub", value: 1200), .init(label: "X", value: 767), .init(label: "Direct/None", value: 483),
                          .init(label: "Hacker News", value: 284), .init(label: "Google", value: 142)]
        report.fetchedAt = Date().addingTimeInterval(-120)
        reports["sample-site|\(AnalyticsRange.week.rawValue)"] = report
    }
}

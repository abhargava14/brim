import AppKit
import IslandCore
import SwiftUI

/// Analytics: visitors, pages and sources for your sites, from DataFast or Google Analytics.
struct AnalyticsTabView: View {
    @ObservedObject var analytics: AnalyticsService
    let connect: () -> Void
    @Environment(\.islandTheme) private var theme

    var body: some View {
        if analytics.sites.isEmpty {
            ConnectCard(symbol: "chart.bar", color: Palette.amber, title: "Connect your site analytics",
                        message: "See visitors, top pages and sources for your sites. Brim only reads stats and can't change anything.",
                        actions: [.init(title: "DataFast", sub: "API key", run: connect),
                                  .init(title: "Google Analytics", sub: "Service account", primary: false, run: connect)],
                        note: "Keys stay in your macOS Keychain.")
        } else {
            VStack(spacing: 10) {
                if let site = analytics.current, let error = analytics.errors[site.id] {
                    WarnBanner(title: analytics.report == nil ? "Can't load" : "Paused",
                               message: error + (analytics.report.map { " These numbers are from \(When.time($0.fetchedAt))." } ?? ""),
                               button: "Update key", action: connect)
                }
                HStack(spacing: 8) {
                    SegmentedPills(options: analytics.sites.map { ($0.id, $0.name) },
                                   selection: Binding(get: { analytics.current?.id ?? "" }, set: { analytics.selected = $0 }))
                    Spacer()
                    if analytics.loading { Spinner(size: 11) }
                    Text("via \(analytics.current?.provider.title ?? "")").font(.brim(11, .bold)).foregroundStyle(theme.f(0.45))
                }
                .fixedSize(horizontal: false, vertical: true)
                if let report = analytics.report {
                    content(report)
                } else {
                    IslandCard {
                        VStack(spacing: 8) {
                            Spinner(size: 16)
                            Text("Loading \(analytics.current?.name ?? "")…").font(.brim(13)).foregroundStyle(theme.f(0.6))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .onAppear { analytics.watch() }
            .onDisappear { analytics.unwatch() }
        }
    }

    private func content(_ report: AnalyticsReport) -> some View {
        HStack(spacing: 10) {
            VStack(spacing: 10) {
                IslandCard(padding: EdgeInsets(top: 10, leading: 12, bottom: 14, trailing: 12)) {
                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            SegmentedPills(options: AnalyticsRange.allCases.map { ($0, $0.title) }, selection: $analytics.range, look: .strong, height: 24)
                            Spacer()
                            if let online = report.online {
                                Circle().fill(Palette.green).frame(width: 6, height: 6)
                                Text("\(online) online").font(.brim(12))
                            }
                        }
                        StatStrip(items: stats(report), valueSize: 24)
                            .padding(.horizontal, -12)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                IslandCard(padding: EdgeInsets(top: 12, leading: 16, bottom: 10, trailing: 16)) {
                    VStack(spacing: 6) {
                        SectionTitle(title: "Visitors", aside: Format.ago(report.fetchedAt))
                        CurveChart(values: report.series.count > 1 ? report.series : [0, report.visitors])
                        HStack {
                            Text(startLabel(report))
                            Spacer()
                            if let peak = report.series.max() { Text("peak \(Self.short(peak))") }
                            Spacer()
                            Text(analytics.range == .today ? "Now" : "Today")
                        }
                        .font(.brim(11, .bold))
                        .foregroundStyle(theme.f(0.4))
                    }
                }
            }
            VStack(spacing: 10) {
                list("Top pages", report.pages)
                list("Sources", report.sources)
            }
            .frame(width: 320)
        }
    }

    private func stats(_ report: AnalyticsReport) -> [StatItem] {
        let change = report.visitorChange
        return [
            StatItem(key: "Visitors", value: Self.short(report.visitors),
                     sub: change.map { ($0 >= 0 ? "↑ " : "↓ ") + "\(abs($0))% vs prior" } ?? "",
                     subColor: (change ?? 0) > 0 ? Palette.green : nil),
            StatItem(key: "Pageviews", value: Self.short(report.pageviews),
                     sub: report.visitors > 0 ? String(format: "%.1f per visitor", report.pageviews / report.visitors) : ""),
            StatItem(key: "Bounce", value: report.bounceRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", sub: "single page"),
            StatItem(key: "Session", value: report.sessionSeconds.map(Self.duration) ?? "–", sub: "average"),
        ]
    }

    private func list(_ title: String, _ rows: [AnalyticsReport.Row]) -> some View {
        IslandCard(padding: EdgeInsets(top: 12, leading: 10, bottom: 8, trailing: 10)) {
            VStack(alignment: .leading, spacing: 2) {
                SectionTitle(title: title, aside: "visitors").padding(.horizontal, 6).padding(.bottom, 4)
                if rows.isEmpty {
                    Text("No data for this range").font(.brim(12, .bold)).foregroundStyle(theme.f(0.4)).padding(.horizontal, 6)
                }
                let top = rows.first?.value ?? 1
                ForEach(Array(rows.prefix(4).enumerated()), id: \.offset) { _, row in
                    ShareRow(label: row.label, value: Self.short(row.value), fraction: row.value / max(top, 1))
                }
            }
        }
    }

    private func startLabel(_ report: AnalyticsReport) -> String {
        if analytics.range == .today { return "00:00" }
        guard let start = report.seriesStart else { return "" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: start)
    }

    /// 2.8k, 412, 11.6k.
    static func short(_ value: Double) -> String {
        value >= 1000 ? String(format: "%.1fk", value / 1000).replacingOccurrences(of: ".0k", with: "k") : String(Int(value.rounded()))
    }

    /// "1m 12s", "58s".
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? "\(total / 60)m \(String(format: "%02d", total % 60))s" : "\(total)s"
    }
}

/// Settings › Connections › Analytics: sites, and adding one with its key.
struct AnalyticsConnections: View {
    @ObservedObject var analytics: AnalyticsService
    @State private var adding = false
    @State private var provider: AnalyticsSite.Provider = .datafast
    @State private var name = ""
    @State private var secret = ""
    @State private var property = ""
    @State private var problem: String?
    @State private var checking = false
    @State private var replacing: String?
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text("Visitors, pages and sources for your sites. Pick one provider per site. Keys are stored in your macOS Keychain and only used to read stats.")
                    .font(.brim(12.5, .medium)).foregroundStyle(theme.f(0.6)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                IslandButton(title: "Add a site", style: .primary, height: 28, symbol: "plus") { adding = true }
            }
            if adding { form }
            SettingsGroup {
                if analytics.sites.isEmpty {
                    Text("No sites yet.").font(.brim(12.5, .medium)).foregroundStyle(theme.f(0.6)).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(analytics.sites.enumerated()), id: \.element.id) { index, site in
                    let error = analytics.errors[site.id]
                    ConnectionLine(symbol: site.provider == .datafast ? "bolt.fill" : "chart.line.uptrend.xyaxis",
                                   tint: site.provider == .datafast ? Palette.amber : Color(red: 0.98, green: 0.67, blue: 0),
                                   title: site.name, detail: error ?? site.provider.title + (site.propertyID.isEmpty ? "" : " · property \(site.propertyID)"),
                                   divider: index > 0) {
                        StatusPill(text: error == nil ? "Connected" : "Needs attention", kind: error == nil ? .ok : .warn)
                        IslandButton(title: "Update key", height: 26, fontSize: 11.5) { replacing = site.id; secret = "" }
                        IslandButton(title: "Remove", style: .destructive, height: 26, fontSize: 11.5) { analytics.remove(site.id) }
                    }
                    if replacing == site.id {
                        HStack(spacing: 8) {
                            SecureField(site.provider == .datafast ? "df_…" : "Paste the service-account JSON", text: $secret)
                                .textFieldStyle(.roundedBorder)
                            IslandButton(title: "Save", style: .primary, height: 26, fontSize: 11.5) {
                                analytics.updateKey(site.id, secret: secret)
                                replacing = nil
                            }
                            IslandButton(title: "Cancel", height: 26, fontSize: 11.5) { replacing = nil }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                    }
                }
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            SegmentedPills(options: AnalyticsSite.Provider.allCases.map { ($0, $0.title) }, selection: $provider, look: .strong, height: 24)
            TextField("Site name, e.g. brim.app", text: $name).textFieldStyle(.roundedBorder)
            if provider == .datafast {
                SecureField("Website API key (df_…)", text: $secret).textFieldStyle(.roundedBorder)
                Text("DataFast › your website › Settings › Developer › API key.")
                    .font(.brim(11.5, .medium)).foregroundStyle(theme.f(0.5))
            } else {
                TextField("GA4 property ID (numbers only)", text: $property).textFieldStyle(.roundedBorder)
                TextEditor(text: $secret)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.f(0.15)))
                Text("Create a service account in Google Cloud, enable the Analytics Data API, add the account's email as a Viewer on the GA4 property, then paste its JSON key here.")
                    .font(.brim(11.5, .medium)).foregroundStyle(theme.f(0.5)).fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem).font(.brim(12, .bold)).foregroundStyle(Palette.amber)
            }
            HStack {
                Spacer()
                IslandButton(title: "Cancel", height: 28) { adding = false; problem = nil }
                IslandButton(title: checking ? "Checking…" : "Connect", style: .primary, height: 28) {
                    checking = true
                    problem = nil
                    Task {
                        let result = await analytics.add(name: name, provider: provider, secret: secret, propertyID: property)
                        checking = false
                        if let result { problem = result } else {
                            adding = false
                            name = ""; secret = ""; property = ""
                        }
                    }
                }
                .disabled(checking || secret.isEmpty)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.f(0.05)))
    }
}

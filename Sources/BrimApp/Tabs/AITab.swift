import AppKit
import IslandCore
import SwiftUI

// MARK: - Model

/// Why an account can't show fresh numbers, and the one fix for it.
enum AIProblem: Equatable {
    case signedOut
    case logsMissing
    case rateLimited
    case other(String)

    init(message: String) {
        let text = message.lowercased()
        if text.contains("sign") || text.contains("expired") || text.contains("401") || text.contains("403") || text.contains("token") || text.contains("key") {
            self = .signedOut
        } else if text.contains("no logs") || text.contains("not found") || text.contains("folder") || text.contains("missing") {
            self = .logsMissing
        } else if text.contains("429") || text.contains("rate") || text.contains("slow down") {
            self = .rateLimited
        } else {
            self = .other(message)
        }
    }

    var status: String {
        switch self {
        case .signedOut: return "Signed out"
        case .logsMissing: return "No logs"
        case .rateLimited: return "Paused"
        case .other: return "Problem"
        }
    }

    var detail: String {
        switch self {
        case .signedOut: return "session expired"
        case .logsMissing: return "folder missing"
        case .rateLimited: return "rate limited"
        case .other: return "can't read"
        }
    }

    /// The word on the account's row in Overview.
    var short: String {
        switch self {
        case .signedOut: return "Sign in"
        case .logsMissing: return "Fix"
        case .rateLimited: return "Paused"
        case .other: return "Fix"
        }
    }

    var button: String {
        switch self {
        case .signedOut: return "Sign in again"
        case .logsMissing: return "Choose folder"
        case .rateLimited, .other: return "Retry now"
        }
    }
}

/// One connected AI account with what the AI tab needs to draw it.
struct AIAccount: Identifiable {
    let connection: Connection
    let tool: ToolSnapshot?
    let problem: AIProblem?
    let problemMessage: String?
    let working: Bool

    var id: String { connection.id }
    var kind: ToolKind { connection.kind }
    var name: String {
        let base = AccountTag.split(connection.name).base
        return base == kind.displayName ? kind.shortName : base
    }
    var tag: String? { connection.tag }
    var label: String { tag.map { "\(name) · \($0)" } ?? name }
    /// Highest plan-window use, the "limit used" figure.
    var lead: Double? { tool?.tightestWindow?.usedPercent }
    var hasTokens: Bool { kind.source == .localLogs }

    var project: String? {
        tool?.sessions.max { $0.lastActivity < $1.lastActivity }?.project
    }

    var mood: GlyphMood { working ? .working : problem != nil ? .dim : .idle }

    /// Plan windows of an account-based tool (Cursor's two pools, Copilot's requests…).
    var limitWindows: [PlanWindow]? {
        guard !hasTokens, let windows = tool?.planWindows, !windows.isEmpty else { return nil }
        return windows
    }

    var source: String {
        switch kind {
        case .claude: return tool?.planWindows.isEmpty == false ? "Local logs + sign-in" : "Local logs"
        case .codex: return tool?.planWindows.isEmpty == false ? "Local logs + limits" : "Local logs"
        case .customLogs: return "Log folder"
        case .openrouter: return "API key"
        case .customEndpoint: return "Usage URL"
        default: return "Sign-in"
        }
    }
}

/// The enabled AI accounts, as the AI tab and its badges see them.
struct AIAccounts {
    let items: [AIAccount]

    @MainActor
    init(model: UsageModel, settings: AppSettings) {
        if BrimQA.skipCredentials {
            // Fixture data has no saved connections behind it.
            items = model.snapshot.tools.map { tool in
                var connection = Connection(id: tool.id, kind: tool.kind, name: tool.name)
                if let tag = AccountTag.split(tool.name).tag { connection.options[Connection.Option.tag] = tag }
                let message = tool.hasData ? nil : tool.statusMessage
                return AIAccount(connection: connection, tool: tool, problem: message.map(AIProblem.init(message:)),
                                 problemMessage: message, working: model.isWorking(tool))
            }
            return
        }
        items = settings.enabledConnections.map { connection in
            let tool = model.snapshot[connection.id]
            var message: String?
            if case .attention(let text) = model.states[connection.id], tool?.hasData != true {
                message = text
            }
            return AIAccount(connection: connection, tool: tool, problem: message.map(AIProblem.init(message:)),
                             problemMessage: message, working: tool.map(model.isWorking) ?? false)
        }
    }

    var problemCount: Int { items.filter { $0.problem != nil }.count }
}

// MARK: - Tab

/// AI: an Overview plus one pill per account. Broken accounts sort first and say what broke.
struct AITabView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var settings: AppSettings
    let addAccount: (AddAccountRequest) -> Void
    let manage: () -> Void
    @State private var selected: String?
    @State private var adding = false
    @State private var spins = 0.0

    init(model: UsageModel, settings: AppSettings, addAccount: @escaping (AddAccountRequest) -> Void,
         manage: @escaping () -> Void, selected: String? = nil, adding: Bool = false) {
        self.model = model
        self.settings = settings
        self.addAccount = addAccount
        self.manage = manage
        _selected = State(initialValue: selected)
        _adding = State(initialValue: adding)
    }
    @Environment(\.islandTheme) private var theme

    private var accounts: AIAccounts { AIAccounts(model: model, settings: settings) }
    private var current: AIAccount? { selected.flatMap { id in accounts.items.first { $0.id == id } } }

    var body: some View {
        let accounts = self.accounts
        VStack(spacing: 10) {
            topRow(accounts)
            if accounts.items.isEmpty {
                AIEmptyView { kind in adding = false; startAdd(kind) }
            } else if let current {
                AIAccountDetail(account: current, model: model, addAccount: addAccount)
            } else {
                AIOverview(accounts: accounts, model: model) { selected = $0 }
            }
        }
        .overlay(alignment: .topTrailing) {
            if adding {
                AIAddPopover(model: model, settings: settings, close: { adding = false }, manage: {
                    adding = false
                    manage()
                }, openWindow: { request in
                    adding = false
                    addAccount(request)
                }, added: { selected = $0 })
                .padding(.top, 30)
                .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
                .zIndex(3)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: adding)
        .onChange(of: settings.connections.map(\.id)) { ids in
            if let selected, !ids.contains(selected) { self.selected = nil }
        }
    }

    private func topRow(_ accounts: AIAccounts) -> some View {
        HStack(spacing: 6) {
            if accounts.items.isEmpty {
                Text("No AI tools connected")
                    .font(.brim(12))
                    .foregroundStyle(theme.f(0.55))
                    .padding(.leading, 4)
            } else {
                IslandScroll(axis: .horizontal) {
                    HStack(spacing: 2) {
                        AccountPill(title: "Overview", symbol: "square.grid.2x2.fill", on: current == nil) { selected = nil }
                        ForEach(accounts.items) { account in
                            AccountPill(account: account, on: account.id == current?.id) { selected = account.id }
                        }
                    }
                    .padding(2)
                }
                .background(Capsule().fill(theme.f(0.06)))
                .clipShape(Capsule())
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Text(updatedText(accounts))
                .font(.brim(11, .bold))
                .foregroundStyle(accounts.items.contains(where: \.working) ? Palette.green : theme.f(0.4))
                .lineLimit(1)
                .fixedSize()
            IconButton(symbol: "arrow.clockwise", help: "Refresh", rotation: spins) {
                withAnimation(.spring(response: 0.7, dampingFraction: 0.8)) { spins += 360 }
                model.refresh(forceAccounts: true)
            }
            IconButton(symbol: "plus", help: "Connect a tool", active: adding, rotation: adding ? 45 : 0) {
                adding.toggle()
            }
        }
    }

    private func updatedText(_ accounts: AIAccounts) -> String {
        if accounts.items.contains(where: \.working) { return "live" }
        guard !accounts.items.isEmpty else { return "" }
        return "updated " + Format.ago(model.snapshot.generatedAt)
    }

    private func startAdd(_ kind: ToolKind) {
        if kind.source == .localLogs, kind != .customLogs {
            adding = true
        } else {
            addAccount(AddAccountRequest(kind: kind))
        }
    }
}

/// An account pill: the logo and tag; the selected one adds the name.
struct AccountPill: View {
    var title: String = ""
    var symbol: String?
    var account: AIAccount?
    let on: Bool
    let pick: () -> Void
    @Environment(\.islandTheme) private var theme
    @State private var hovering = false

    init(title: String, symbol: String, on: Bool, pick: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.on = on
        self.pick = pick
    }

    init(account: AIAccount, on: Bool, pick: @escaping () -> Void) {
        self.account = account
        self.on = on
        self.pick = pick
    }

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                Text(title).font(.brim(12))
            } else if let account {
                ToolGlyph(kind: account.kind, mood: account.mood, size: 13, name: account.connection.name)
                if on || account.tag == nil { Text(account.name).font(.brim(12)) }
                if let tag = account.tag { Text(tag).font(.brim(10.5)).opacity(0.6) }
                if account.problem != nil {
                    Circle().fill(Palette.amber).frame(width: 5, height: 5)
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.leading, 9)
        .padding(.trailing, 11)
        .frame(height: 26)
        .foregroundStyle(on ? theme.fg : theme.f(0.65))
        .background(Capsule().fill(on ? theme.f(0.16) : hovering ? theme.f(0.1) : .clear))
        .overlay {
            if account?.problem != nil && !on { Capsule().strokeBorder(Palette.amber.opacity(0.35)) }
        }
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onTapGesture(perform: pick)
        .help(account?.label ?? title)
        .accessibilityElement()
        .accessibilityLabel(account?.label ?? title)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Overview

struct AIOverview: View {
    let accounts: AIAccounts
    @ObservedObject var model: UsageModel
    let pick: (String) -> Void
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let logs = accounts.items.filter(\.hasTokens)
        let series = AIStats.dailySeries(logs.compactMap(\.tool))
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 10) {
                IslandCard(padding: EdgeInsets(top: 15, leading: 6, bottom: 14, trailing: 6)) {
                    StatStrip(items: stats(series: series))
                }
                .fixedSize(horizontal: false, vertical: true)
                IslandCard(padding: EdgeInsets(top: 14, leading: 18, bottom: 12, trailing: 18)) {
                    TokensChart(title: "Tokens · 14 days", aside: "\(logs.count) log source\(logs.count == 1 ? "" : "s")",
                                values: series, color: nil)
                }
            }
            .frame(maxWidth: .infinity)
            .layoutPriority(1.6)
            IslandCard(padding: EdgeInsets(top: 14, leading: 12, bottom: 8, trailing: 12)) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionTitle(title: "Accounts", aside: "limit used").padding(.horizontal, 6).padding(.bottom, 6)
                    IslandScroll {
                        VStack(spacing: 2) {
                            ForEach(sorted) { account in
                                AccountRow(account: account) { pick(account.id) }
                            }
                        }
                    }
                }
            }
            .frame(width: 318)
        }
    }

    private var sorted: [AIAccount] {
        accounts.items.sorted {
            let a = ($0.problem != nil ? 1 : 0, $0.lead ?? -1), b = ($1.problem != nil ? 1 : 0, $1.lead ?? -1)
            return a.0 != b.0 ? a.0 > b.0 : a.1 > b.1
        }
    }

    private func stats(series: [Double]) -> [StatItem] {
        let total = accounts.items.reduce(Int64(0)) { $0 + ($1.hasTokens ? ($1.tool?.today.total ?? 0) : 0) }
        let previous = series.dropLast()
        let average = previous.isEmpty ? 0 : previous.reduce(0, +) / Double(previous.count)
        var deltaText = "today"
        var deltaColor: Color?
        if average > 0 {
            let delta = Int(((series.last ?? 0) / average - 1) * 100)
            deltaText = (delta >= 0 ? "↑ " : "↓ ") + "\(abs(delta))% vs avg"
            deltaColor = delta >= 0 ? Palette.green : nil
        }
        let working = accounts.items.filter(\.working)
        let near = accounts.items.filter { $0.problem == nil && $0.lead != nil }.max { ($0.lead ?? 0) < ($1.lead ?? 0) }
        let problems = accounts.problemCount
        return [
            StatItem(key: "Tokens today", value: Format.tokens(total), sub: deltaText, subColor: deltaColor),
            StatItem(key: "Working", value: "\(working.count)",
                     sub: working.isEmpty ? "all idle" : working.compactMap(\.project).joined(separator: ", ").ifEmpty("active"),
                     subColor: working.isEmpty ? nil : theme.fg),
            StatItem(key: "Nearest limit", value: near.map { Format.percent($0.lead ?? 0) } ?? "–",
                     sub: near?.label ?? "", valueColor: near.flatMap { Palette.warm($0.lead ?? 0) }),
            StatItem(key: "Accounts", value: "\(accounts.items.count)",
                     sub: problems > 0 ? "\(problems) need attention" : "all healthy", subColor: problems > 0 ? Palette.amber : nil),
        ]
    }
}

/// An account in Overview: glyph, name, tag, working dot, limit bar and value.
struct AccountRow: View {
    let account: AIAccount
    let pick: () -> Void
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            ToolGlyph(kind: account.kind, mood: account.mood, size: 14, name: account.connection.name)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(account.name).font(.brim(12.5, .bold)).lineLimit(1)
                    if let tag = account.tag {
                        Text(tag)
                            .font(.brim(10))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 5).fill(theme.f(0.1)))
                            .foregroundStyle(theme.f(0.6))
                            .fixedSize()
                    }
                    if account.working {
                        PulseDot(color: account.kind.tint)
                    }
                }
                if let plan = account.tool?.planName, account.problem == nil {
                    Text(plan).font(.brim(10.5, .bold)).foregroundStyle(theme.f(0.45)).lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            if let problem = account.problem {
                Text(problem.short).font(.brim(12.5)).foregroundStyle(Palette.amber)
            } else if let windows = account.limitWindows, windows.count > 1 {
                // Plans with more than one pool (Cursor models and other models) show each.
                VStack(spacing: 3) {
                    ForEach(Array(windows.prefix(3).enumerated()), id: \.offset) { _, window in
                        MiniBar(fraction: window.usedPercent / 100, color: Palette.fuel(window.usedPercent), height: 3)
                    }
                }
                .frame(width: 54)
                HStack(spacing: 3) {
                    ForEach(Array(windows.prefix(3).enumerated()), id: \.offset) { index, window in
                        if index > 0 { Text("·").foregroundStyle(theme.f(0.35)) }
                        Text(Format.percent(window.usedPercent)).foregroundStyle(Palette.warm(window.usedPercent) ?? theme.fg)
                    }
                }
                .font(.brim(12.5))
                .fixedSize()
                .help(windows.map { "\($0.label): \(Format.percent($0.usedPercent))" }.joined(separator: "\n"))
            } else if let lead = account.lead {
                MiniBar(fraction: lead / 100, color: Palette.fuel(lead)).frame(width: 54)
                Text(Format.percent(lead))
                    .font(.brim(12.5))
                    .foregroundStyle(Palette.warm(lead) ?? theme.fg)
                    .frame(minWidth: 36, alignment: .trailing)
            } else {
                Text(account.hasTokens ? Format.tokens(account.tool?.today.total ?? 0) : "–")
                    .font(.brim(12.5))
                    .frame(minWidth: 36, alignment: .trailing)
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(minHeight: 30)
        .hoverFill(10, base: account.problem != nil ? Palette.amber.opacity(0.1) : .clear, hover: theme.f(0.12))
        .onTapGesture(perform: pick)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A soft pulsing dot for "working right now".
struct PulseDot: View {
    let color: Color
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(on ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// "TOKENS · 14 DAYS" with a curve and first / peak / last labels.
struct TokensChart: View {
    let title: String
    let aside: String
    let values: [Double]
    var color: Color?
    var peakText: String?
    var formatter: (Double) -> String = { Format.tokens(Int64($0)) }
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "chart.xyaxis.line").font(.system(size: 11, weight: .bold))
                SectionTitle(title: title, aside: aside)
            }
            if values.contains(where: { $0 > 0 }) {
                CurveChart(values: values, color: color, endDot: true)
            } else {
                Text("No history yet. It fills in as you use the tool.")
                    .font(.brim(12, .bold))
                    .foregroundStyle(theme.f(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Text(AIStats.dayLabel(back: values.count - 1))
                Spacer()
                Text(peakText ?? peak)
                Spacer()
                Text("Today")
            }
            .font(.brim(11, .bold))
            .foregroundStyle(theme.f(0.4))
        }
    }

    private var peak: String {
        guard let top = values.max(), top > 0, let index = values.firstIndex(of: top) else { return "" }
        return "peak \(formatter(top)) · \(AIStats.dayLabel(back: values.count - 1 - index))"
    }
}

enum AIStats {
    /// Tokens per day for the last 14 days, oldest first, summed across tools.
    static func dailySeries(_ tools: [ToolSnapshot], days: Int = 14, now: Date = Date()) -> [Double] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var series = Array(repeating: 0.0, count: days)
        for tool in tools {
            for point in tool.daily {
                let day = calendar.startOfDay(for: point.date)
                guard let back = calendar.dateComponents([.day], from: day, to: today).day, back >= 0, back < days else { continue }
                series[days - 1 - back] += Double(point.tokens.total)
            }
        }
        // Today may be newer than the last daily point.
        let todayTotal = tools.reduce(0.0) { $0 + Double($1.today.total) }
        series[days - 1] = max(series[days - 1], todayTotal)
        return series
    }

    static func dayLabel(back: Int, now: Date = Date()) -> String {
        guard back > 0 else { return "Today" }
        let date = Calendar.current.date(byAdding: .day, value: -back, to: now) ?? now
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: date)
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

// MARK: - One account

struct AIAccountDetail: View {
    let account: AIAccount
    @ObservedObject var model: UsageModel
    let addAccount: (AddAccountRequest) -> Void
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 10) {
                IslandCard(padding: EdgeInsets(top: 15, leading: 6, bottom: 14, trailing: 6)) {
                    StatStrip(items: stats)
                }
                .fixedSize(horizontal: false, vertical: true)
                if let problem = account.problem {
                    problemCard(problem)
                } else if account.hasTokens {
                    IslandCard(padding: EdgeInsets(top: 14, leading: 18, bottom: 12, trailing: 18)) {
                        TokensChart(title: "Tokens · 14 days", aside: account.tool?.planName ?? account.source,
                                    values: AIStats.dailySeries(account.tool.map { [$0] } ?? []), color: account.kind.tint)
                    }
                } else {
                    let history = model.quotaHistory.series(account.id).map { $0 ?? 0 }
                    IslandCard(padding: EdgeInsets(top: 14, leading: 18, bottom: 12, trailing: 18)) {
                        TokensChart(title: "Cycle used · 14 days", aside: account.tool?.planName ?? "",
                                    values: history, color: account.kind.tint,
                                    peakText: account.lead.map { Format.percent($0) + " today" },
                                    formatter: { Format.percent($0) })
                    }
                }
            }
            .frame(maxWidth: .infinity)
            IslandCard(padding: EdgeInsets(top: 14, leading: 12, bottom: 8, trailing: 12)) {
                IslandScroll {
                    VStack(alignment: .leading, spacing: 12) {
                        if account.problem == nil, account.hasTokens, let tool = account.tool {
                            breakdown(tool)
                        }
                        accountSection
                    }
                }
            }
            .frame(width: 318)
        }
    }

    private var stats: [StatItem] {
        let tool = account.tool
        if let problem = account.problem {
            let last = tool?.updatedAt.map { Self.time($0) } ?? "–"
            return [
                StatItem(key: "Status", value: problem.status, sub: problem.detail, valueColor: Palette.amber, subColor: Palette.amber),
                StatItem(key: "Plan", value: tool?.planName ?? "–", sub: account.name),
                StatItem(key: "Last read", value: last, sub: "last good data"),
                StatItem(key: "Usage", value: problem == .rateLimited ? (account.lead.map(Format.percent) ?? "–") : "–",
                         sub: problem == .rateLimited ? "may be stale" : "unknown"),
            ]
        }
        guard let tool else { return [StatItem(key: "Status", value: "Connecting…")] }
        if account.hasTokens {
            var items: [StatItem] = []
            let windows = Self.mainWindows(tool.planWindows)
            for window in windows {
                items.append(StatItem(key: Self.shortLabel(window), value: Format.percent(window.usedPercent),
                                      sub: window.resetsAt.map { "resets in " + Format.countdown(to: $0) } ?? "",
                                      valueColor: Palette.warm(window.usedPercent), subColor: Palette.warm(window.usedPercent)))
            }
            items.append(StatItem(key: "Today", value: Format.tokens(tool.today.total), sub: "\(tool.todayRequests) requests"))
            if account.working, let project = account.project {
                items.append(StatItem(key: "Working on", value: project, sub: tool.topModel.map(Format.modelName) ?? ""))
            } else {
                items.append(StatItem(key: "Sessions", value: "\(tool.todaySessions)", sub: tool.topModel.map(Format.modelName) ?? ""))
            }
            if windows.isEmpty {
                items.insert(StatItem(key: "Week", value: Format.tokens(tool.week.total), sub: "7 days"), at: 0)
                items.insert(StatItem(key: "5 hours", value: Format.tokens(tool.last5Hours.total), sub: "tokens"), at: 0)
            }
            return Array(items.prefix(4))
        }
        // One cell per pool, so a full "Other models" never hides "Cursor models".
        let windows = Array(tool.planWindows.prefix(2))
        var items = windows.map { window in
            StatItem(key: window.label, value: Format.percent(window.usedPercent), sub: window.detail ?? "used",
                     valueColor: Palette.warm(window.usedPercent), subColor: Palette.warm(window.usedPercent))
        }
        if items.isEmpty { items.append(StatItem(key: "Used", value: "–", sub: "no limits reported")) }
        let reset = tool.planWindows.compactMap(\.resetsAt).min()
        items.append(StatItem(key: "Resets", value: reset.map { Format.countdown(to: $0) } ?? "–",
                              sub: reset == nil ? "no reset" : Self.day(reset!)))
        if items.count < 4 { items.append(StatItem(key: "Pace", value: pace, sub: "used this week")) }
        items.append(StatItem(key: "Plan", value: tool.planName ?? "Unknown", sub: tool.updatedAt.map { "updated " + Format.ago($0) } ?? ""))
        return Array(items.prefix(4))
    }

    private var pace: String {
        let series = model.quotaHistory.series(account.id, days: 8)
        guard let today = series.last ?? nil, let weekAgo = series.first ?? nil else { return "–" }
        return Format.percent(max(0, today - weekAgo))
    }

    private func problemCard(_ problem: AIProblem) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "exclamationmark")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(Palette.amber)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Palette.amber.opacity(0.18)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title(problem)).font(.brim(15))
                Text(message(problem))
                    .font(.brim(12, .bold))
                    .foregroundStyle(theme.f(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            IslandButton(title: problem.button, style: .tint(Palette.amber), height: 32, fontSize: 12.5) { fix(problem) }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.amber.opacity(0.1)))
    }

    private func title(_ problem: AIProblem) -> String {
        switch problem {
        case .signedOut: return "Signed out of \(account.label)"
        case .logsMissing: return "Can't find logs for \(account.label)"
        case .rateLimited: return "\(account.name) asked Brim to slow down"
        case .other: return "\(account.label) needs attention"
        }
    }

    private func message(_ problem: AIProblem) -> String {
        switch problem {
        case .signedOut: return "Brim stopped reading this account. Your other accounts keep updating."
        case .logsMissing: return "The log folder was moved or hasn't been written yet. Point Brim at the folder this account writes to."
        case .rateLimited: return "Brim retries in a few minutes. The numbers you see may be old."
        case .other(let text): return text
        }
    }

    private func fix(_ problem: AIProblem) {
        switch problem {
        case .signedOut:
            addAccount(AddAccountRequest(connectionID: account.id))
        case .logsMissing:
            FolderPicker.choose(message: "Choose the folder \(account.label) writes its logs to") { url in
                var connection = account.connection
                let key = connection.kind == .claude ? Connection.Option.configDir : Connection.Option.path
                connection.options[key] = url.path
                model.settings.update(connection)
                model.refresh(forceAccounts: true)
            }
        case .rateLimited, .other:
            model.refresh(forceAccounts: true)
        }
    }

    private func breakdown(_ tool: ToolSnapshot) -> some View {
        let tint = account.kind.tint
        let parts: [(String, Int64, Color)] = [
            ("Input", tool.today.input, theme.f(0.9)),
            ("Output", tool.today.output, tint),
            ("Cache write", tool.today.cacheWrite, tint.opacity(0.55)),
            ("Cache read", tool.today.cacheRead, tint.opacity(0.28)),
        ]
        let sum = max(Double(tool.today.total), 1)
        return VStack(alignment: .leading, spacing: 2) {
            SectionTitle(title: "Today by type", aside: "tokens").padding(.horizontal, 6).padding(.bottom, 4)
            ForEach(parts, id: \.0) { name, value, color in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 8, height: 8)
                    Text(name).font(.brim(12.5, .bold)).foregroundStyle(theme.f(0.7))
                    Spacer(minLength: 6)
                    MiniBar(fraction: Double(value) / sum, color: color).frame(width: 54)
                    Text(Format.tokens(value)).font(.brim(12.5)).frame(minWidth: 44, alignment: .trailing)
                }
                .monospacedDigit()
                .padding(.horizontal, 8)
                .frame(minHeight: 28)
            }
        }
    }

    private var accountSection: some View {
        let tool = account.tool
        return VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Account").padding(.horizontal, 6).padding(.bottom, 4)
            DetailRow(key: "Account", value: account.tag.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Default")
            DetailRow(key: "Plan", value: tool?.planName ?? "–")
            DetailRow(key: "Source", value: account.source)
            if let label = model.accountLabel(for: account.id) {
                DetailRow(key: "Signed in as", value: label)
            }
            if !account.hasTokens, account.problem == nil, let windows = tool?.planWindows, !windows.isEmpty {
                ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                    HStack(spacing: 8) {
                        Text(window.label).font(.brim(12.5, .bold)).foregroundStyle(theme.f(0.7)).lineLimit(1)
                        Spacer(minLength: 6)
                        MiniBar(fraction: window.usedPercent / 100, color: Palette.fuel(window.usedPercent)).frame(width: 54)
                        Text(window.detail ?? Format.percent(window.usedPercent))
                            .font(.brim(12.5))
                            .foregroundStyle(Palette.warm(window.usedPercent) ?? theme.fg)
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                    .padding(.horizontal, 8)
                    .frame(minHeight: 30)
                }
                DetailRow(key: "Resets", value: windows.compactMap(\.resetsAt).min().map { Self.day($0) } ?? "no reset")
            }
            if account.hasTokens, let windows = tool?.planWindows, windows.count > 2 {
                ForEach(Array(windows.dropFirst(2).enumerated()), id: \.offset) { _, window in
                    DetailRow(key: window.label, value: Format.percent(window.usedPercent), valueColor: Palette.warm(window.usedPercent))
                }
            }
            DetailRow(key: "Last update", value: tool?.updatedAt.map { Format.ago($0) } ?? "–",
                      valueColor: account.problem != nil ? Palette.amber : theme.f(0.5))
        }
    }

    /// The 5-hour and weekly windows, in that order, when the tool reports them.
    static func mainWindows(_ windows: [PlanWindow]) -> [PlanWindow] {
        let session = windows.first { $0.label.lowercased().contains("session") || $0.label.lowercased().contains("5h") || $0.label.lowercased().contains("5-hour") }
        let week = windows.first { $0.label.lowercased().contains("week") && $0.model == nil }
        let picked = [session, week].compactMap { $0 }
        return picked.isEmpty ? Array(windows.prefix(2)) : picked
    }

    static func shortLabel(_ window: PlanWindow) -> String {
        let label = window.label.lowercased()
        if label.contains("session") || label.contains("5h") || label.contains("5-hour") { return "5h limit" }
        if label.contains("week") { return "Week" }
        return window.label
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Empty

/// First run inside the AI tab: one tile per tool, each opening the same Add flow.
struct AIEmptyView: View {
    let pick: (ToolKind) -> Void
    @Environment(\.islandTheme) private var theme

    private let tools: [ToolKind] = [.claude, .codex, .cursor, .windsurf, .copilot, .openrouter, .customLogs, .customEndpoint]

    var body: some View {
        IslandCard(padding: EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22)) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect your AI tools").font(.brim(17))
                    Text("Token counts come from local logs on this Mac. Plan limits come from signing in. Brim never reads your prompts or code.")
                        .font(.brim(12.5, .bold))
                        .foregroundStyle(theme.f(0.6))
                        .frame(maxWidth: 560, alignment: .leading)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(tools) { kind in
                        HStack(spacing: 11) {
                            ToolGlyph(kind: kind, size: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(kind.shortName).font(.brim(13))
                                Text(AIAddPopover.hint(for: kind)).font(.brim(11, .bold)).foregroundStyle(theme.f(0.5))
                            }
                            .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 62)
                        .hoverFill(15, base: theme.f(0.07), hover: theme.f(0.13))
                        .onTapGesture { pick(kind) }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                    }
                }
            }
        }
    }
}

// MARK: - Add flow

/// The + popover: pick a tool, pick how to read it, then label the account.
/// Sign-in and API-key methods hand over to the Add Account window, which owns those flows.
struct AIAddPopover: View {
    enum Step: Equatable {
        case list
        case method(ToolKind)
        case name(String)
    }

    @ObservedObject var model: UsageModel
    @ObservedObject var settings: AppSettings
    let close: () -> Void
    let manage: () -> Void
    let openWindow: (AddAccountRequest) -> Void
    let added: (String) -> Void
    @State private var step: Step = .list
    @State private var labelDraft = ""
    @State private var chosenLabel: String?
    @Environment(\.islandTheme) private var theme

    static let tools: [ToolKind] = [.claude, .codex, .cursor, .windsurf, .copilot, .openrouter, .customLogs, .customEndpoint]

    static func hint(for kind: ToolKind) -> String {
        switch kind {
        case .claude, .codex: return "Local logs · sign in"
        case .copilot: return "Sign in with GitHub"
        case .openrouter: return "API key"
        case .customLogs: return "Any log folder"
        case .customEndpoint: return "Any JSON URL"
        default: return "Sign in"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch step {
            case .list: list
            case .method(let kind): methods(kind)
            case .name(let id): nameStep(id)
            }
        }
        .padding(8)
        .frame(width: 296, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(theme.pop))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.f(0.1)))
        .shadow(color: .black.opacity(0.45), radius: 20, y: 14)
        .onExitCommand(perform: close)
    }

    private func count(_ kind: ToolKind) -> Int { settings.connections.filter { $0.kind == kind }.count }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionTitle(title: "Connect a tool", opacity: 0.5).padding(.horizontal, 8).padding(.vertical, 4)
            ForEach(Self.tools) { kind in
                let n = count(kind)
                HStack(spacing: 9) {
                    ToolGlyph(kind: kind, size: 15)
                    Text(kind.shortName).font(.brim(12.5))
                    Spacer()
                    Text(n > 0 ? "\(n) connected" : Self.hint(for: kind))
                        .font(.brim(11, .bold))
                        .foregroundStyle(n > 0 ? Palette.green : theme.f(0.45))
                }
                .padding(.leading, 8)
                .padding(.trailing, 10)
                .frame(height: 28)
                .hoverFill(10, hover: theme.f(0.1))
                .onTapGesture { choose(kind) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
            }
            Rectangle().fill(theme.f(0.08)).frame(height: 1).padding(.horizontal, 6).padding(.vertical, 4)
            Text("Manage accounts in Settings…")
                .font(.brim(12))
                .foregroundStyle(theme.f(0.6))
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .hoverFill(10, hover: theme.f(0.08))
                .onTapGesture(perform: manage)
                .accessibilityAddTraits(.isButton)
        }
    }

    private func choose(_ kind: ToolKind) {
        if kind == .claude || kind == .codex {
            withAnimation(.easeOut(duration: 0.15)) { step = .method(kind) }
        } else {
            openWindow(AddAccountRequest(kind: kind))
        }
    }

    private func header(_ kind: ToolKind, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.left")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 24)
                .hoverFill(12, hover: theme.f(0.1))
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { step = .list } }
                .accessibilityLabel("Back")
                .accessibilityAddTraits(.isButton)
            ToolGlyph(kind: kind, size: 16)
            Text(title).font(.brim(13.5))
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private func methods(_ kind: ToolKind) -> some View {
        let existing = count(kind)
        let folder = kind == .claude ? "~/.claude" : "~/.codex"
        let found = FileManager.default.fileExists(atPath: (folder as NSString).expandingTildeInPath)
        return VStack(alignment: .leading, spacing: 4) {
            header(kind, title: kind.shortName)
            methodCard(title: "Read local logs",
                       sub: existing > 0 ? "Choose another config folder" : found ? "Found \(folder) on this Mac" : "\(folder) not found yet",
                       recommended: true) { addLocal(kind, chooseFolder: existing > 0) }
            methodCard(title: kind == .claude ? "Sign in to Claude" : "Sign in with ChatGPT",
                       sub: "Adds your 5h and weekly limits", recommended: false) {
                openWindow(AddAccountRequest(kind: kind))
            }
        }
    }

    private func methodCard(title: String, sub: String, recommended: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.brim(12.5))
                    if recommended {
                        Text("RECOMMENDED")
                            .font(.brim(9.5))
                            .kerning(0.6)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Brand.good.opacity(0.18)))
                            .foregroundStyle(Brand.good)
                    }
                }
                Text(sub).font(.brim(11, .bold)).foregroundStyle(theme.f(0.5))
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).opacity(0.4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .hoverFill(12, base: theme.f(0.06), hover: theme.f(0.12))
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func addLocal(_ kind: ToolKind, chooseFolder: Bool) {
        let finish: ([String: String]) -> Void = { options in
            let connection = model.addAccount(kind, options: options)
            withAnimation(.easeOut(duration: 0.15)) { step = .name(connection.id) }
        }
        guard chooseFolder else { return finish([:]) }
        FolderPicker.choose(message: "Choose the \(kind.shortName) config folder for this account") { url in
            let key = kind == .claude ? Connection.Option.configDir : Connection.Option.path
            finish([key: url.path])
        }
    }

    private func nameStep(_ id: String) -> some View {
        let connection = settings.connection(id)
        let kind = connection?.kind ?? .claude
        let same = settings.connections.filter { $0.kind == kind }.count > 1
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Brand.good)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Brand.good.opacity(0.18)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(kind.shortName) connected").font(.brim(13.5))
                    Text("Reading local logs").font(.brim(11, .bold)).foregroundStyle(theme.f(0.55))
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 10)
            SectionTitle(title: "Label this account", opacity: 0.5).padding(.horizontal, 8).padding(.bottom, 6)
            HStack(spacing: 6) {
                ForEach(AccountTag.suggestions, id: \.self) { label in
                    let on = chosenLabel == label
                    Text(label)
                        .font(.brim(12))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .foregroundStyle(on ? theme.bg : theme.fg)
                        .background(Capsule().fill(on ? theme.fg : theme.f(0.1)))
                        .onTapGesture { chosenLabel = on ? nil : label; labelDraft = "" }
                        .accessibilityAddTraits(.isButton)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)
            PlainTextField("Or type a label", text: $labelDraft, font: .brim(12, .bold))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.f(0.08)))
                .padding(.horizontal, 4)
                .onChange(of: labelDraft) { if !$0.isEmpty { chosenLabel = nil } }
            Text(same ? "Needed because you have more than one \(kind.shortName) account. Shown as a tag on its tab."
                      : "Optional. It becomes a tag if you add a second \(kind.shortName) account later.")
                .font(.brim(11, .bold))
                .foregroundStyle(theme.f(0.5))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            IslandButton(title: "Done", style: .primary, height: 32, fontSize: 12.5) {
                let label = labelDraft.isEmpty ? chosenLabel : labelDraft
                if var connection = settings.connection(id), let label, !label.isEmpty {
                    connection.setTag(label)
                    settings.update(connection)
                }
                added(id)
                close()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
        }
    }
}

/// Picks a folder from the island, which never takes focus on its own.
enum FolderPicker {
    @MainActor
    static func choose(message: String, then: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = message
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { then(url) }
    }
}

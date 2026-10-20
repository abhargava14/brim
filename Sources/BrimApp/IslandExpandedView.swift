import IslandCore
import SwiftUI

// MARK: - Expanded

struct ExpandedView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: IslandState
    let openSettings: () -> Void
    let addAccount: (AddAccountRequest) -> Void
    @State private var appeared = false

    var body: some View {
        let tools = model.featuredTools
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: (state.hasNotch ? 44 : 40) - 10)

            HStack(spacing: 5) {
                Text("Today").foregroundStyle(.white.opacity(0.6))
                Text("·").foregroundStyle(.white.opacity(0.35))
                RollingText(text: model.snapshot.usageTodayHeadline)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                Text("·").foregroundStyle(.white.opacity(0.35))
                Text("\(tools.count) connected").foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                Spacer()
                RoundButton(symbol: "plus", help: "Add account") { addAccount(AddAccountRequest()) }
                RoundButton(symbol: "arrow.clockwise", help: "Refresh now") { model.refresh(forceAccounts: true) }
                RoundButton(symbol: "gearshape.fill", help: "Settings", action: openSettings)
            }
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .monospacedDigit()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                        ToolCard(tool: tool, model: model, openSettings: openSettings, addAccount: addAccount)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : -10)
                            .scaleEffect(appeared ? 1 : 0.98, anchor: .top)
                            .animation(.spring(response: 0.34, dampingFraction: 0.82).delay(0.14 + Double(min(index, 8)) * 0.05), value: appeared)
                    }
                }
                .padding(.bottom, tools.count > 3 ? 24 : 0)
            }
            .frame(maxHeight: 560)
            .fixedSize(horizontal: false, vertical: tools.count <= 3)
            .mask(
                VStack(spacing: 0) {
                    Color.black
                    if tools.count > 3 {
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 36)
                    }
                }
            )
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .foregroundStyle(.white)
        .onAppear { appeared = true }
    }
}

struct ToolCard: View {
    let tool: ToolSnapshot
    @ObservedObject var model: UsageModel
    let openSettings: () -> Void
    let addAccount: (AddAccountRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let account = model.accountLabel(for: tool.id) {
                Text(account)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, -6)
            }
            if let message = tool.statusMessage, !tool.hasData {
                ProblemRow(message: message, action: fix)
            } else if tool.kind == .claude, model.claudeStyle(for: tool.id) == .full {
                ClaudeDetailView(tool: tool, model: model)
            } else if tool.hasTokenData {
                tokenDetails
            } else {
                accountDetails
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.07)))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture {
            guard tool.kind == .claude, tool.hasData else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { model.toggleClaudeStyle(for: tool.id) }
        }
    }

    private var isAccount: Bool { tool.kind.source == .account }

    /// Account problems are fixed by signing in again; log problems by choosing the folder in Settings.
    private var fix: ProblemRow.Action {
        isAccount
            ? .init(title: "Sign in") { addAccount(AddAccountRequest(connectionID: tool.id)) }
            : .init(title: "Choose folder", run: openSettings)
    }

    private var header: some View {
        HStack(spacing: 6) {
            ToolGlyph(kind: tool.kind, mood: model.isWorking(tool) ? .working : .idle, size: 15, playful: model.settings.playful, name: tool.name)
            Text(tool.name)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .lineLimit(1)
            if let plan = tool.planName {
                Text(plan)
                    .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tool.kind.tint.opacity(0.16)))
                    .foregroundStyle(tool.kind.tint)
            }
            Spacer(minLength: 6)
            if let model = tool.topModel {
                Text(Format.modelName(model))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            } else if isAccount, let updated = tool.updatedAt {
                Text("updated \(Format.ago(updated))")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    @ViewBuilder
    private var tokenDetails: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            RollingText(text: Format.tokens(tool.today.total))
                .font(.system(size: 24, weight: .heavy, design: .rounded))
            Text("tokens today")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(tool.kind == .claude && !tool.sessions.isEmpty
                  ? tool.sessionSummary()
                  : "\(tool.todaySessions) sessions · \(tool.todayRequests) req")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
        }
        .monospacedDigit()

        if model.isWorking(tool) {
            WorkingLine(tint: tool.kind.tint)
        }

        TokenBreakdown(tokens: tool.today, tint: tool.kind.tint)

        ForEach(tool.planWindows.filter { $0.model == nil }, id: \.label) { window in
            PlanBar(window: window)
        }
        if tool.kind == .claude { ClaudeLimitsNote(tool: tool) }
        if tool.kind == .claude, tool.planWindows.isEmpty, tool.limitsNote == nil, model.claudeConnection == .notConnected {
            Button { try? model.connectClaudePlan() } label: {
                Label("Show Claude plan limits (5h / weekly)", systemImage: "link")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(tool.kind.tint)
        }

        HistoryBars(points: Array(tool.daily.suffix(14)), tint: tool.kind.tint)

        HStack(spacing: 10) {
            Text("14 days").foregroundStyle(.white.opacity(0.35))
            Spacer()
            ForEach([("5h", tool.last5Hours), ("7d", tool.week), ("30d", tool.month)], id: \.0) { key, counts in
                HStack(spacing: 3) {
                    Text(key).foregroundStyle(.white.opacity(0.35))
                    Text(Format.tokens(counts.total)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .font(.system(size: 10.5, weight: .bold, design: .rounded))
        .monospacedDigit()

        if tool.kind == .claude { ClaudeStyleToggle(tool: tool, model: model) }
    }

    @ViewBuilder
    private var accountDetails: some View {
        if tool.planWindows.isEmpty {
            Text("Connected. The service didn't report any limits for this plan.")
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
        }
        ForEach(tool.planWindows, id: \.label) { window in
            QuotaRow(window: window)
        }
        if let message = tool.statusMessage {
            ProblemRow(message: message, action: fix)
        }
    }
}

/// 26pt round header button.
struct RoundButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .bold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.16 : 0.08)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A connection that needs the user: what went wrong and a way to fix it.
struct ProblemRow: View {
    struct Action {
        var title: String
        var run: () -> Void
    }

    let message: String
    let action: Action

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.attention)
            Text(message)
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: action.run) {
                Text(action.title)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Brand.attention.opacity(0.16)))
                    .foregroundStyle(Brand.attention)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11.5, weight: .bold, design: .rounded))
    }
}

/// "Working" with a pulsing dot while the tool's logs are being written.
struct WorkingLine: View {
    let tint: Color
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6).opacity(pulse ? 0.35 : 1)
            Text("Working").foregroundStyle(.white.opacity(0.6))
        }
        .font(.system(size: 11.5, weight: .bold, design: .rounded))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// An account quota: a label row ("Premium requests · 212 / 300 · resets in 13d") over a full-width bar.
struct QuotaRow: View {
    let window: PlanWindow
    @State private var filled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(window.label).foregroundStyle(.white.opacity(0.6))
                Text("·").foregroundStyle(.white.opacity(0.35))
                Text(Format.used(window))
                    .foregroundStyle(window.usedPercent >= 80 ? PlanBar.color(for: window.usedPercent) : .white)
                if let reset = window.resetsAt {
                    Text("· \(Format.reset(reset))").foregroundStyle(.white.opacity(0.35))
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(PlanBar.color(for: window.usedPercent))
                        .frame(width: max(4, geometry.size.width * (filled ? min(window.usedPercent, 100) : 0) / 100))
                }
            }
            .frame(height: 6)
        }
        .font(.system(size: 11.5, weight: .bold, design: .rounded))
        .monospacedDigit()
        .onAppear {
            withAnimation(.timingCurve(0.25, 1, 0.4, 1, duration: 0.9).delay(0.3)) { filled = true }
        }
    }
}

/// A stacked bar of input, output, cache write and cache read, with a legend.
struct TokenBreakdown: View {
    let tokens: TokenCounts
    let tint: Color

    private struct Part: Identifiable {
        let name: String
        let value: Int64
        let color: Color
        var id: String { name }
    }

    private var parts: [Part] {
        [
            Part(name: "input", value: tokens.input, color: Color.white.opacity(0.9)),
            Part(name: "output", value: tokens.output, color: tint),
            Part(name: "cache write", value: tokens.cacheWrite, color: tint.opacity(0.55)),
            Part(name: "cache read", value: tokens.cacheRead, color: tint.opacity(0.28)),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                HStack(spacing: 1.5) {
                    ForEach(parts.filter { $0.value > 0 }) { part in
                        Rectangle()
                            .fill(part.color)
                            .frame(width: max(2, geometry.size.width * CGFloat(part.value) / CGFloat(max(tokens.total, 1))))
                    }
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())

            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                    if index > 0 { Spacer(minLength: 6) }
                    HStack(spacing: 4) {
                        Circle().fill(part.color).frame(width: 6, height: 6)
                        Text(part.name).foregroundStyle(.white.opacity(0.35))
                        Text(Format.tokens(part.value)).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .font(.system(size: 10.5, weight: .bold, design: .rounded))
            .lineLimit(1)
            .monospacedDigit()
        }
    }
}

/// A plan window as a bar that fills up like a fuel gauge.
struct PlanBar: View {
    let window: PlanWindow
    @State private var filled = false

    static func color(for percent: Double) -> Color {
        switch percent {
        case ..<80: return Brand.good
        case ..<95: return Brand.attention
        default: return Brand.limit
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(window.label)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .frame(width: 38, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(Self.color(for: window.usedPercent))
                        .frame(width: max(4, geometry.size.width * (filled ? min(window.usedPercent, 100) : 0) / 100))
                }
            }
            .frame(height: 6)
            Text(Format.used(window))
                .foregroundStyle(window.usedPercent >= 80 ? Self.color(for: window.usedPercent) : .white.opacity(0.6))
                .lineLimit(1)
                .frame(minWidth: 62, alignment: .trailing)
            Text(window.resetsAt.map { Format.reset($0) } ?? "")
                .foregroundStyle(.white.opacity(0.35))
                .lineLimit(1)
                .frame(width: 84, alignment: .trailing)
        }
        .font(.system(size: 11.5, weight: .bold, design: .rounded))
        .monospacedDigit()
        .onAppear {
            withAnimation(.timingCurve(0.25, 1, 0.4, 1, duration: 0.9).delay(0.3)) { filled = true }
        }
    }
}

/// Daily tokens for the last two weeks; today is highlighted.
struct HistoryBars: View {
    let points: [DailyPoint]
    let tint: Color

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter
    }()

    var body: some View {
        let peak = max(Double(points.map(\.tokens.total).max() ?? 0), 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(point.tokens.total == 0 ? Color.white.opacity(0.12) : index == points.count - 1 ? tint : tint.opacity(0.45))
                    .frame(height: max(2, 28 * CGFloat(Double(point.tokens.total) / peak)))
                    .frame(maxWidth: .infinity)
                    .help("\(Self.dayFormatter.string(from: point.date)): \(Format.tokens(point.tokens.total)) tokens")
            }
        }
        .frame(height: 28, alignment: .bottom)
    }
}

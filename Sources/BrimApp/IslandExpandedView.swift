import AppKit
import IslandCore
import SwiftUI

// MARK: - Expanded (design v2 · Cards / Strip)

/// Horizontal expanded island: Cards (196pt) or Strip (108pt) columns, Add pinned on the right.
struct ExpandedView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: IslandState
    let openSettings: () -> Void
    let addAccount: (AddAccountRequest) -> Void
    @State private var appeared = false
    /// Shared row height from `EqualHeightHStack` — locks Add’s dashed frame to card height.
    @State private var rowHeight: CGFloat = 0

    private var tools: [ToolSnapshot] { model.featuredTools }
    private var isStrip: Bool { settings.expandedLayout == .strip }
    private var cardWidth: CGFloat { isStrip ? 108 : 196 }
    private var cardGap: CGFloat { isStrip ? 6 : 8 }
    private var addWidth: CGFloat { isStrip ? 84 : 96 }
    private var addRadius: CGFloat { isStrip ? 16 : 18 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: (state.hasNotch ? 44 : 40) - 10)

            header

            // EqualHeightHStack = shared *ideal* height. `fixedSize(vertical:)` stops horizontal
            // ScrollView from stretching the cross-axis to the island panel/canvas height.
            ScrollView(.horizontal, showsIndicators: false) {
                EqualHeightHStack(spacing: cardGap) {
                    ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                        Group {
                            if isStrip {
                                StripConnectionCard(tool: tool, model: model, addAccount: addAccount)
                            } else {
                                WideConnectionCard(tool: tool, model: model, addAccount: addAccount)
                            }
                        }
                        .frame(width: cardWidth, alignment: .topLeading)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : -10)
                        .scaleEffect(appeared ? 1 : 0.98, anchor: .top)
                        .animation(
                            .spring(response: 0.34, dampingFraction: 0.82)
                                .delay(0.14 + Double(min(index, 8)) * 0.04),
                            value: appeared
                        )
                    }

                    addTile
                }
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { rowHeight = geo.size.height }
                            .onChange(of: geo.size.height) { rowHeight = $0 }
                    }
                )
                .padding(.trailing, 4)
                .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
            .mask(
                HStack(spacing: 0) {
                    Color.black
                    if tools.count > (isStrip ? 6 : 3) {
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 44)
                    }
                }
            )
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .foregroundStyle(.white)
        .onAppear {
            appeared = true
            syncGeometry()
        }
        .onChange(of: tools.count) { _ in syncGeometry() }
        .onChange(of: settings.expandedLayout) { _ in syncGeometry() }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Text("Today").foregroundStyle(.white.opacity(0.6))
            Text("·").foregroundStyle(.white.opacity(0.35))
            RollingText(text: model.snapshot.usageTodayHeadline)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
            Text("·").foregroundStyle(.white.opacity(0.35))
            Text("\(tools.count) connected").foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            Spacer()
            RoundButton(symbol: "arrow.clockwise", help: "Refresh now") { model.refresh(forceAccounts: true) }
            RoundButton(symbol: "gearshape.fill", help: "Settings", action: openSettings)
        }
        .font(.system(size: 13, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .monospacedDigit()
    }

    /// Dashed Add tile — same Add Account flow as the menu / Connections.
    /// `rowHeight` sizes the dashed frame to the card row; label is `.position`’d at the
    /// frame’s geometric center (ZStack / Spacer / overlay alignment all stayed top-biased).
    private var addTile: some View {
        let height = rowHeight > 0 ? rowHeight : nil
        return RoundedRectangle(cornerRadius: addRadius, style: .continuous)
            .strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .frame(width: addWidth, height: height)
            .overlay {
                GeometryReader { geo in
                    VStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .bold))
                        Text("Add")
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: addRadius, style: .continuous))
            .onTapGesture { addAccount(AddAccountRequest()) }
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help("Add Account…")
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Add Account")
    }

    private func syncGeometry() {
        state.expandedToolCount = tools.count
        state.expandedLayoutIsStrip = isStrip
    }
}

// MARK: - Wide card (1a)

struct WideConnectionCard: View {
    let tool: ToolSnapshot
    @ObservedObject var model: UsageModel
    let addAccount: (AddAccountRequest) -> Void

    private var isError: Bool { tool.statusMessage != nil && !tool.hasData }
    private var working: Bool { model.isWorking(tool) }
    private var title: String { tool.name.split(separator: "·").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? tool.name }
    private var tag: String? {
        guard model.snapshot.tools.filter({ $0.kind == tool.kind }).count > 1 else { return nil }
        return model.wingSuffix(for: tool)
    }
    private var windows: [PlanWindow] { tool.displayPlanWindows }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                ToolGlyph(kind: tool.kind, mood: isError ? .dim : (working ? .working : .idle), size: 15, playful: model.settings.playful, name: tool.name)
                Text(title)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                if let tag {
                    Text(tag)
                        .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.1)))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
                if working {
                    Circle().fill(tool.kind.tint).frame(width: 6, height: 6)
                }
            }

            if isError {
                Text("Signed out")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(Brand.attention)
                Button {
                    addAccount(AddAccountRequest(connectionID: tool.id))
                } label: {
                    Text("Sign in again")
                        .font(.system(size: 11.5, weight: .heavy, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(Capsule().fill(Brand.attention.opacity(0.16)))
                        .foregroundStyle(Brand.attention)
                }
                .buttonStyle(.plain)
            } else if !windows.isEmpty {
                PlanWindowsList(windows: windows, kind: tool.kind, style: .island, showBars: true)
            } else if tool.hasTokenData {
                Text(Format.tokens(tool.today.total))
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                Text("tokens today")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                Text("Connected")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Text(footLine)
                    .font(.system(size: 11, weight: .bold, design: working ? .monospaced : .rounded))
                    .foregroundStyle(working ? .white : .white.opacity(0.35))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let plan = tool.planName {
                    Text(plan)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
            }
            .padding(.top, 8)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private var footLine: String {
        if working { return tool.sessions.first?.project ?? "Working" }
        if tool.hasTokenData { return "\(Format.tokens(tool.today.total)) today" }
        if let updated = tool.updatedAt { return "updated \(Format.ago(updated))" }
        return tool.statusMessage ?? ""
    }
}

// MARK: - Strip column (1b)

struct StripConnectionCard: View {
    let tool: ToolSnapshot
    @ObservedObject var model: UsageModel
    let addAccount: (AddAccountRequest) -> Void

    private var isError: Bool { tool.statusMessage != nil && !tool.hasData }
    private var working: Bool { model.isWorking(tool) }
    private var windows: [PlanWindow] { tool.displayPlanWindows }
    private var stripTitle: String {
        var name = tool.name.replacingOccurrences(of: "GitHub ", with: "")
        if let short = model.wingSuffix(for: tool), model.snapshot.tools.filter({ $0.kind == tool.kind }).count > 1 {
            name = "\(name.split(separator: "·").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? name) · \(short)"
        }
        return name
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ToolGlyph(kind: tool.kind, mood: isError ? .dim : (working ? .working : .idle), size: 18, playful: model.settings.playful, name: tool.name)
                    .frame(maxWidth: .infinity)
                if working {
                    Circle().fill(tool.kind.tint).frame(width: 6, height: 6).padding(2)
                }
            }
            Text(stripTitle)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            if isError {
                Text("Sign in")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(Brand.attention)
                Text("expired")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.attention)
            } else if !windows.isEmpty {
                PlanWindowsList(windows: windows, kind: tool.kind, style: .strip)
            } else {
                Text(tool.hasTokenData ? Format.tokens(tool.today.total) : "—")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.top, 13)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.07)))
        .contentShape(Rectangle())
        .onTapGesture {
            if isError { addAccount(AddAccountRequest(connectionID: tool.id)) }
        }
    }
}

// MARK: - Shared chrome (kept for detail / Claude full cards)

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

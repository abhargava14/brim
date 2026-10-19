import IslandCore
import SwiftUI

// MARK: - Root

struct IslandView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: IslandState
    let openSettings: () -> Void

    private var cornerRadius: CGFloat { state.isExpanded ? 26 : state.barHeight / 2.2 }
    private var width: CGFloat {
        state.isExpanded ? IslandState.expandedWidth : state.compactWidth(forEvent: model.event != nil)
    }

    var body: some View {
        island
            .frame(width: IslandController.canvas.width, height: IslandController.canvas.height, alignment: .top)
            .environment(\.colorScheme, .dark)
    }

    private var island: some View {
        ZStack(alignment: .top) {
            if state.isExpanded {
                ExpandedView(model: model, settings: settings, state: state, openSettings: openSettings)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else if let event = model.event {
                EventView(event: event, state: state, playful: settings.playful)
                    .id(event.id)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity))
            } else {
                CompactView(model: model, state: state)
                    .transition(.opacity)
            }
        }
        .frame(width: width)
        .frame(height: state.isExpanded ? nil : state.barHeight)
        .background(NotchShape(bottomRadius: cornerRadius).fill(Color.black))
        .overlay(EventGlow(event: state.isExpanded ? nil : model.event, radius: cornerRadius))
        .clipShape(NotchShape(bottomRadius: cornerRadius))
        .shadow(color: .black.opacity(state.isExpanded ? 0.45 : 0), radius: 18, y: 8)
        .overlay(alignment: .top) {
            if let event = model.event, event.celebrates, settings.playful, !state.isExpanded {
                ConfettiBurst(colors: [event.kind.tint, .white, .yellow, .green])
                    .id(event.id)
                    .allowsHitTesting(false)
            }
        }
        .background(
            GeometryReader { geometry in
                Color.clear.preference(key: IslandSizeKey.self, value: geometry.size)
            }
        )
        .onPreferenceChange(IslandSizeKey.self) { size in
            state.islandSize = size
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if model.event != nil && !state.isExpanded { model.dismissEvent() }
            state.isExpanded.toggle()
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: state.isExpanded)
        .animation(.spring(response: 0.42, dampingFraction: 0.7), value: model.event?.id)
    }
}

private struct IslandSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Square top edge (it hangs from the screen edge), rounded bottom corners like the notch.
struct NotchShape: Shape {
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(bottomRadius, rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Tool styling

extension ToolKind {
    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(red: 0.45, green: 0.78, blue: 1.0)
        case .cursor: return Color(red: 0.86, green: 0.86, blue: 0.9)
        case .windsurf: return Color(red: 0.2, green: 0.88, blue: 0.7)
        case .copilot: return Color(red: 0.64, green: 0.44, blue: 0.97)
        case .openrouter: return Color(red: 0.42, green: 0.55, blue: 1.0)
        case .customLogs: return Color(red: 0.95, green: 0.78, blue: 0.3)
        case .customEndpoint: return Color(red: 0.98, green: 0.5, blue: 0.66)
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .windsurf: return "wind"
        case .copilot: return "airplane"
        case .openrouter: return "arrow.triangle.branch"
        case .customLogs: return "folder.fill"
        case .customEndpoint: return "link"
        }
    }
}

enum GlyphMood: Equatable {
    case idle, working, attention, celebrate
}

/// The tool's icon, with a little personality: it turns while working, bounces when it needs
/// attention and spins once to celebrate.
struct ToolGlyph: View {
    let kind: ToolKind
    var mood: GlyphMood = .idle
    var size: CGFloat = 11
    var playful = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    private var animated: Bool { playful && !reduceMotion }

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(mood == .attention ? Color.orange : kind.tint)
            .rotationEffect(.degrees(rotation))
            .scaleEffect(scale)
            .offset(y: offsetY)
            .opacity(mood == .working && kind != .claude && animated && phase ? 0.45 : 1)
            .onAppear { start() }
            .onChange(of: mood) { _ in phase = false; start() }
    }

    private var rotation: Double {
        guard animated else { return 0 }
        switch mood {
        case .working: return kind == .claude && phase ? 360 : 0
        case .celebrate: return phase ? 360 : 0
        default: return 0
        }
    }

    private var scale: CGFloat {
        guard animated else { return 1 }
        return mood == .celebrate && phase ? 1.25 : 1
    }

    private var offsetY: CGFloat {
        guard animated else { return 0 }
        return mood == .attention && phase ? -3 : 0
    }

    private func start() {
        guard animated else { return }
        switch mood {
        case .idle:
            break
        case .working:
            let animation: Animation = kind == .claude
                ? .linear(duration: 2.4).repeatForever(autoreverses: false)
                : .easeInOut(duration: 0.55).repeatForever(autoreverses: true)
            withAnimation(animation) { phase = true }
        case .attention:
            withAnimation(.spring(response: 0.25, dampingFraction: 0.35).repeatCount(3, autoreverses: true)) { phase = true }
        case .celebrate:
            withAnimation(.spring(response: 0.6, dampingFraction: 0.55)) { phase = true }
        }
    }
}

/// Numbers that roll like an odometer when they change (macOS 14+; a cross-fade before that).
struct RollingText: View {
    let text: String

    var body: some View {
        if #available(macOS 14.0, *) {
            Text(text)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: text)
        } else {
            Text(text)
                .id(text)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: text)
        }
    }
}

/// A short burst of particles out of the notch for milestones and new connections.
struct ConfettiBurst: View {
    let colors: [Color]
    @State private var fired = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(0..<18, id: \.self) { index in
                let angle = Double.pi * (0.08 + 0.84 * Double(index) / 17)
                let distance = 46.0 + Double((index * 29) % 44)
                RoundedRectangle(cornerRadius: 1)
                    .fill(colors[index % colors.count])
                    .frame(width: index % 3 == 0 ? 3 : 4, height: index % 3 == 0 ? 6 : 4)
                    .rotationEffect(.degrees(fired ? Double(index * 47) : 0))
                    .offset(x: fired ? cos(angle) * distance * (index % 2 == 0 ? 1 : -1) * 1.6 : 0,
                            y: fired ? sin(angle) * distance * 0.7 + 14 : 10)
                    .opacity(fired ? 0 : 1)
            }
        }
        .frame(height: 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.1)) { fired = true }
        }
    }
}

/// A coloured rim and a light sweep along the island while an event shows.
struct EventGlow: View {
    let event: IslandEvent?
    let radius: CGFloat
    @State private var sweep = false

    private var color: Color? {
        switch event?.style {
        case .warning: return .orange
        case .limit: return .red
        case .connected, .milestone: return .green
        case .disconnected, .none: return nil
        }
    }

    var body: some View {
        if let color {
            ZStack {
                NotchShape(bottomRadius: radius).stroke(color.opacity(0.9), lineWidth: 1.5)
                GeometryReader { geometry in
                    LinearGradient(colors: [.clear, color.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geometry.size.width * 0.35)
                        .offset(x: sweep ? geometry.size.width : -geometry.size.width * 0.35)
                }
            }
            .allowsHitTesting(false)
            .onAppear {
                sweep = false
                withAnimation(.easeInOut(duration: 1.2)) { sweep = true }
            }
        }
    }
}

// MARK: - Compact

struct CompactView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var state: IslandState

    /// With more than two tools, the wings take turns every few seconds.
    private static let pageSeconds: Double = 4

    var body: some View {
        let tools = model.featuredTools
        TimelineView(.periodic(from: .now, by: Self.pageSeconds)) { context in
            let pages = max(1, Int(ceil(Double(tools.count) / 2)))
            // The most urgent pair always shows first and stays while something is urgent.
            let urgent = tools.first.map { ($0.tightestWindow?.usedPercent ?? 0) >= 95 || model.isWorking($0) } ?? false
            let page = urgent ? 0 : Int(context.date.timeIntervalSince1970 / Self.pageSeconds) % pages
            let pair = Array(tools.dropFirst(page * 2).prefix(2))
            content(pair, total: tools.count, page: page, pages: pages)
                .id(page)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .move(edge: .top).combined(with: .opacity)))
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: page)
        }
        .clipped()
    }

    @ViewBuilder
    private func content(_ pair: [ToolSnapshot], total: Int, page: Int, pages: Int) -> some View {
        HStack(spacing: 0) {
            wing(pair.first, alignment: .leading)
            if state.hasNotch {
                Spacer().frame(width: state.notchWidth)
            } else {
                Spacer(minLength: 8)
            }
            if pair.count > 1 {
                wing(pair[1], alignment: .trailing)
            } else {
                detailWing(pair.first)
            }
        }
        .padding(.horizontal, 14)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if pages > 1 { PageDots(count: pages, current: page).padding(.bottom, 2) }
        }
    }

    private func mood(_ tool: ToolSnapshot) -> GlyphMood {
        if (tool.tightestWindow?.usedPercent ?? 0) >= 95 { return .attention }
        return model.isWorking(tool) ? .working : .idle
    }

    @ViewBuilder
    private func wing(_ tool: ToolSnapshot?, alignment: HorizontalAlignment) -> some View {
        HStack(spacing: 5) {
            if let tool {
                if alignment == .trailing { Spacer(minLength: 0) }
                ToolGlyph(kind: tool.kind, mood: mood(tool), playful: model.settings.playful)
                RollingText(text: model.compactValue(for: tool))
                    .foregroundStyle(valueColor(tool))
                    .lineLimit(1)
                if alignment == .leading { Spacer(minLength: 0) }
            } else {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                Text("Connect").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: state.hasNotch ? IslandState.wingWidth - 14 : .infinity)
    }

    /// With a single tool, the right wing shows its tightest window or today's tokens.
    @ViewBuilder
    private func detailWing(_ tool: ToolSnapshot?) -> some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if let tool, let window = tool.tightestWindow {
                Text("\(window.label) \(Format.percent(window.usedPercent))")
                    .foregroundStyle(PlanBar.color(for: window.usedPercent))
            } else if let tool, tool.hasTokenData {
                RollingText(text: Format.tokens(tool.today.total))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: state.hasNotch ? IslandState.wingWidth - 14 : .infinity)
    }

    private func valueColor(_ tool: ToolSnapshot) -> Color {
        guard let percent = tool.tightestWindow?.usedPercent, percent >= 80 else { return .white }
        return PlanBar.color(for: percent)
    }
}

struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<min(count, 8), id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(index == current ? 0.8 : 0.25))
                    .frame(width: index == current ? 6 : 3, height: 2)
            }
        }
    }
}

// MARK: - Event moments

struct EventView: View {
    let event: IslandEvent
    @ObservedObject var state: IslandState
    let playful: Bool

    private var mood: GlyphMood {
        switch event.style {
        case .connected, .milestone: return .celebrate
        case .warning, .limit: return .attention
        case .disconnected: return .idle
        }
    }

    private var accent: Color {
        switch event.style {
        case .connected, .milestone: return .green
        case .warning: return .orange
        case .limit: return .red
        case .disconnected: return .secondary
        }
    }

    private var icon: String? {
        switch event.style {
        case .connected: return "checkmark.circle.fill"
        case .milestone: return "party.popper.fill"
        case .warning: return "gauge.with.dots.needle.67percent"
        case .limit: return "hand.raised.fill"
        case .disconnected: return "bolt.horizontal.circle"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ToolGlyph(kind: event.kind, mood: mood, size: 12, playful: playful)
                Text(event.title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: state.hasNotch ? IslandState.eventWingWidth - 14 : .infinity)
            if state.hasNotch { Spacer().frame(width: state.notchWidth) } else { Spacer(minLength: 8) }
            HStack(spacing: 5) {
                Spacer(minLength: 0)
                Text(event.detail).foregroundStyle(.secondary).lineLimit(1)
                if let icon { Image(systemName: icon).foregroundStyle(accent) }
            }
            .frame(maxWidth: state.hasNotch ? IslandState.eventWingWidth - 14 : .infinity)
        }
        .padding(.horizontal, 14)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.white)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: IslandState
    let openSettings: () -> Void
    @State private var appeared = false

    var body: some View {
        let tools = model.featuredTools
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: max(state.barHeight - 6, 4))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Today")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                RollingText(text: "\(Format.tokens(model.snapshot.todayTokens)) tokens")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text("· \(tools.count) connected")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(action: { model.refresh(forceAccounts: true) }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh now")
                Button(action: openSettings) {
                    Image(systemName: "gearshape.fill")
                }
                .help("Settings")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .monospacedDigit()

            if tools.isEmpty {
                Button(action: openSettings) {
                    Label("Connect your first AI tool", systemImage: "plus.circle.fill")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.plain)
                .padding(.vertical, 8)
            }

            ScrollView(.vertical, showsIndicators: tools.count > 3) {
                VStack(spacing: 8) {
                    ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                        ToolCard(tool: tool, model: model, openSettings: openSettings)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : -10)
                            .animation(.spring(response: 0.45, dampingFraction: 0.8).delay(Double(min(index, 8)) * 0.04), value: appeared)
                    }
                }
            }
            .frame(maxHeight: 470)
            .fixedSize(horizontal: false, vertical: tools.count <= 2)

            Text("Logs are read locally. Account tools are checked every 5 minutes.")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
        .onAppear { appeared = true }
    }
}

struct ToolCard: View {
    let tool: ToolSnapshot
    @ObservedObject var model: UsageModel
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if let message = tool.statusMessage, !tool.hasData {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if tool.hasTokenData {
                tokenDetails
            } else {
                accountDetails
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private var header: some View {
        HStack(spacing: 6) {
            ToolGlyph(kind: tool.kind, mood: model.isWorking(tool) ? .working : .idle, size: 12, playful: model.settings.playful)
            Text(tool.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if let plan = tool.planName {
                Text(plan)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(tool.kind.tint.opacity(0.22)))
                    .foregroundStyle(tool.kind.tint)
            }
            if let model = tool.topModel {
                Text(Format.modelName(model))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let updated = tool.updatedAt {
                Text(Format.ago(updated))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var tokenDetails: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            RollingText(text: Format.tokens(tool.today.total))
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("tokens today")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Stat(label: "sessions", value: "\(tool.todaySessions)")
            Stat(label: "requests", value: "\(tool.todayRequests)")
        }
        .monospacedDigit()

        TokenBreakdown(tokens: tool.today, tint: tool.kind.tint)

        ForEach(tool.planWindows, id: \.label) { window in
            PlanBar(window: window)
        }
        if tool.kind == .claude, tool.planWindows.isEmpty, model.claudeConnection != .connected {
            Button(action: openSettings) {
                Label("Connect Claude plan limits (5h / weekly) in Settings", systemImage: "link")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(tool.kind.tint)
        }

        HistoryBars(points: Array(tool.daily.suffix(14)), tint: tool.kind.tint)

        HStack(spacing: 12) {
            Text("5h \(Format.tokens(tool.last5Hours.total))")
            Text("7d \(Format.tokens(tool.week.total))")
            Text("30d \(Format.tokens(tool.month.total))")
            Spacer()
            if let last = tool.lastActivity {
                Text(Format.ago(last))
            }
        }
        .font(.system(size: 10.5, weight: .medium, design: .rounded))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    @ViewBuilder
    private var accountDetails: some View {
        if tool.planWindows.isEmpty {
            Text("Connected. The service didn't report any limits for this plan.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(tool.planWindows, id: \.label) { window in
            PlanBar(window: window)
        }
        if let message = tool.statusMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            RollingText(text: value).font(.system(size: 13, weight: .semibold, design: .rounded))
            Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary)
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
            Part(name: "In", value: tokens.input, color: tint),
            Part(name: "Out", value: tokens.output, color: tint.opacity(0.7)),
            Part(name: "Cache write", value: tokens.cacheWrite, color: Color.white.opacity(0.45)),
            Part(name: "Cache read", value: tokens.cacheRead, color: Color.white.opacity(0.2)),
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

            HStack(spacing: 10) {
                ForEach(parts) { part in
                    HStack(spacing: 4) {
                        Circle().fill(part.color).frame(width: 6, height: 6)
                        Text("\(part.name) \(Format.tokens(part.value))")
                    }
                }
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
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
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(window.label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .frame(width: 70, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(Self.color(for: window.usedPercent))
                        .frame(width: max(4, geometry.size.width * (filled ? window.usedPercent : 0) / 100))
                }
            }
            .frame(height: 6)
            Text(window.detail.map { "\($0)" } ?? Format.percent(window.usedPercent))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .frame(minWidth: 36, alignment: .trailing)
            if let reset = window.resetsAt {
                Text(Format.countdown(to: reset))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .monospacedDigit()
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.85).delay(0.1)) { filled = true }
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
                    .fill(index == points.count - 1 ? tint : tint.opacity(0.4))
                    .frame(height: max(2, 30 * CGFloat(Double(point.tokens.total) / peak)))
                    .frame(maxWidth: .infinity)
                    .help("\(Self.dayFormatter.string(from: point.date)): \(Format.tokens(point.tokens.total)) tokens")
            }
        }
        .frame(height: 30, alignment: .bottom)
    }
}

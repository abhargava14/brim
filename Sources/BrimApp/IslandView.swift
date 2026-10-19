import IslandCore
import SwiftUI

// MARK: - Root

struct IslandView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: IslandState
    let openSettings: () -> Void

    private var cornerRadius: CGFloat { state.isExpanded ? (state.isEmpty ? 22 : 28) : (state.hasNotch ? 14 : 16) }
    private var width: CGFloat {
        state.isExpanded ? state.expandedWidth : state.compactWidth(for: model.event?.style)
    }

    var body: some View {
        island
            .offset(x: state.isExpanded ? 0 : state.xOffset(for: model.event?.style))
            .frame(width: IslandController.canvas.width, height: IslandController.canvas.height, alignment: .top)
            .environment(\.colorScheme, .dark)
    }

    private var island: some View {
        ZStack(alignment: .top) {
            if state.isExpanded && state.isEmpty {
                EmptyPanel(settings: settings, state: state, openSettings: openSettings)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else if state.isExpanded {
                ExpandedView(model: model, settings: settings, state: state, openSettings: openSettings)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else if let event = model.event {
                EventView(event: event, state: state, playful: settings.playful)
                    .id(event.id)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 4)).animation(.easeOut(duration: 0.2).delay(0.08)),
                                            removal: .opacity))
            } else if state.isEmpty {
                EmptyCompactView(state: state)
                    .transition(.opacity)
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
        .shadow(color: .black.opacity(state.isExpanded ? 0.35 : 0), radius: 25, y: 18)
        .shadow(color: .black.opacity(state.isExpanded ? 0.2 : 0), radius: 7, y: 4)
        .overlay(alignment: .top) {
            if let event = model.event, event.celebrates, settings.playful, !state.isExpanded {
                ConfettiBurst(colors: event.style == .milestone
                              ? [event.kind.tint, .white, event.kind.tint.opacity(0.6)]
                              : [Brand.good, .white, event.kind.tint, Color(red: 0x9B / 255, green: 0xE7 / 255, blue: 0xAE / 255)])
                    .id(event.id)
                    .allowsHitTesting(false)
            }
        }
        .background(
            // Written straight to the state: a preference from here isn't delivered through NSHostingView.
            GeometryReader { geometry in
                Color.clear
                    .onAppear { state.islandSize = geometry.size }
                    .onChange(of: geometry.size) { size in state.islandSize = size }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if model.event != nil && !state.isExpanded { model.dismissEvent() }
            if !state.expansionLocked { state.isExpanded.toggle() }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: state.isExpanded)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: model.event?.id)
    }
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
        case .customLogs, .customEndpoint: return Color.white.opacity(0.85)
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
    case idle, working, attention, celebrate, dim
}

/// The design's semantic colours. Amber and red only ever mean "attention" and "limit".
enum Brand {
    static let good = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)
    static let attention = Color(red: 1, green: 0x9F / 255, blue: 0x0A / 255)
    static let limit = Color(red: 1, green: 0x45 / 255, blue: 0x3A / 255)
}

/// The tool's icon, with a little personality: it turns while working, bounces when it needs
/// attention and spins once to celebrate.
struct ToolGlyph: View {
    let kind: ToolKind
    var mood: GlyphMood = .idle
    var size: CGFloat = 11
    var playful = true
    /// Custom connections show the first letter of this name instead of a logo.
    var name: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    private var animated: Bool { playful && !reduceMotion }

    var body: some View {
        mark
            .foregroundStyle(mood == .attention ? Brand.attention : kind.tint)
            .opacity(mood == .dim ? 0.35 : 1)
            .rotationEffect(.degrees(rotation))
            .scaleEffect(scale)
            .offset(y: offsetY)
            .opacity(mood == .working && kind != .claude && animated && phase ? 0.4 : 1)
            .onAppear { start() }
            .onChange(of: mood) { _ in phase = false; start() }
    }

    @ViewBuilder
    private var mark: some View {
        if let logo = BrimAssets.logo(for: kind) {
            Image(nsImage: logo)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else if let letter = name?.trimmingCharacters(in: .whitespaces).first {
            Text(String(letter).uppercased())
                .font(.system(size: size * 0.95, weight: .heavy, design: .rounded))
                .frame(width: size, height: size)
        } else {
            Image(systemName: kind.symbol)
                .font(.system(size: size, weight: .bold))
        }
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
        case .idle, .dim:
            break
        case .working:
            let animation: Animation = kind == .claude
                ? .linear(duration: 6).repeatForever(autoreverses: false)
                : .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
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
        case .warning: return Brand.attention
        case .limit: return Brand.limit
        case .connected: return Brand.good
        case .milestone, .disconnected, .none: return nil
        }
    }

    private var sweeps: Bool { event != nil && event?.style != .disconnected }

    var body: some View {
        if sweeps {
            ZStack {
                if let color {
                    NotchShape(bottomRadius: radius)
                        .stroke(color, lineWidth: 1.5)
                        .shadow(color: color.opacity(0.45), radius: 8)
                }
                GeometryReader { geometry in
                    LinearGradient(colors: [.clear, .white.opacity(0.17), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 90)
                        .offset(x: sweep ? geometry.size.width : -90)
                }
                .clipShape(NotchShape(bottomRadius: radius))
            }
            .allowsHitTesting(false)
            .onAppear {
                sweep = false
                withAnimation(.easeInOut(duration: 1.1).delay(0.15)) { sweep = true }
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
            // `featuredTools` puts urgent and working tools first; the pages keep turning regardless.
            let page = Int(context.date.timeIntervalSince1970 / Self.pageSeconds) % pages
            let pair = Array(tools.dropFirst(page * 2).prefix(2))
            content(pair, total: tools.count, page: page, pages: pages)
                .id(page)
                .transition(.asymmetric(
                    insertion: .offset(y: 13).combined(with: .opacity).animation(.spring(response: 0.46, dampingFraction: 0.72)),
                    removal: .offset(y: -13).combined(with: .opacity).animation(.easeIn(duration: 0.28))
                ))
                .animation(.spring(response: 0.46, dampingFraction: 0.72), value: page)
        }
        .clipped()
    }

    @ViewBuilder
    private func content(_ pair: [ToolSnapshot], total: Int, page: Int, pages: Int) -> some View {
        HStack(spacing: state.hasNotch ? 0 : 16) {
            wing(pair.first, alignment: .leading)
            if state.hasNotch {
                Spacer().frame(width: state.notchWidth)
            }
            if pair.count > 1 {
                wing(pair[1], alignment: .trailing)
            } else if pages > 1 {
                totalWing
            } else {
                detailWing(pair.first)
            }
        }
        .padding(.horizontal, 13)
        .font(.system(size: 12.5, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if pages > 1 { PageDots(count: pages, current: page).padding(.bottom, 4) }
        }
    }

    private func mood(_ tool: ToolSnapshot) -> GlyphMood {
        if tool.statusMessage != nil && !tool.hasData { return .dim }
        if (tool.tightestWindow?.usedPercent ?? 0) >= 95 { return .attention }
        return model.isWorking(tool) ? .working : .idle
    }

    @ViewBuilder
    private func wing(_ tool: ToolSnapshot?, alignment: HorizontalAlignment) -> some View {
        HStack(spacing: 6) {
            if let tool {
                if alignment == .trailing { Spacer(minLength: 0) }
                ToolGlyph(kind: tool.kind, mood: mood(tool), size: 14, playful: model.settings.playful, name: tool.name)
                if alignment == .leading || !glyphOnly {
                    RollingText(text: model.compactValue(for: tool))
                        .foregroundStyle(valueColor(tool))
                        .lineLimit(1)
                    if let suffix = model.wingSuffix(for: tool) { Suffix(text: suffix) }
                }
                if alignment == .leading { Spacer(minLength: 0) }
            } else {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                Text("Connect").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: wingWidth(alignment))
    }

    private var glyphOnly: Bool { state.rightWingWidth(for: nil) < IslandState.glyphOnlyWidth }

    private func wingWidth(_ alignment: HorizontalAlignment) -> CGFloat {
        guard state.hasNotch else { return .infinity }
        let wing = alignment == .leading ? state.leftWingWidth(for: nil) : state.rightWingWidth(for: nil)
        return max(0, wing - 13)
    }

    /// With a single tool, the right wing shows today's tokens (or, for account tools, the
    /// tightest window when the left wing doesn't already show it).
    @ViewBuilder
    private func detailWing(_ tool: ToolSnapshot?) -> some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if glyphOnly {
                EmptyView()
            } else if let tool, tool.hasTokenData {
                RollingText(text: Format.tokens(tool.today.total))
                Suffix(text: "today")
            } else if let tool, let window = tool.tightestWindow, model.compactValue(for: tool) != Format.percent(window.usedPercent) {
                Text("\(window.label) \(Format.percent(window.usedPercent))")
                    .foregroundStyle(valueColor(tool))
            }
        }
        .lineLimit(1)
        .frame(maxWidth: wingWidth(.trailing))
    }

    /// The odd last page of the carousel: today's total across every connection.
    private var totalWing: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if !glyphOnly {
                RollingText(text: Format.tokens(model.snapshot.todayTokens)).foregroundStyle(.white.opacity(0.6))
                Suffix(text: "today")
            }
        }
        .lineLimit(1)
        .frame(maxWidth: wingWidth(.trailing))
    }

    private func valueColor(_ tool: ToolSnapshot) -> Color {
        if tool.statusMessage != nil && !tool.hasData { return Brand.attention }
        guard let percent = tool.tightestWindow?.usedPercent, percent >= 80 else { return .white }
        return PlanBar.color(for: percent)
    }
}

/// A small unit after a wing value: "today", "tok", or the account's short name.
struct Suffix: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.35))
            .lineLimit(1)
    }
}

struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<min(count, 8), id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(index == current ? 1 : 0.3))
                    .frame(width: 4, height: 4)
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
        case .disconnected: return .dim
        }
    }

    private var titleColor: Color {
        switch event.style {
        case .connected, .milestone: return .white
        case .warning: return Brand.attention
        case .limit: return Brand.limit
        case .disconnected: return .white.opacity(0.6)
        }
    }

    /// "resets in 1h 20m": the lead-in is quiet, the time stands out.
    private var detail: Text {
        let quiet = Color.white.opacity(0.6)
        for lead in ["resets in ", "back in "] where event.detail.hasPrefix(lead) {
            return Text(lead).foregroundColor(quiet) + Text(event.detail.dropFirst(lead.count)).foregroundColor(.white)
        }
        let plain = event.style == .connected
        return Text(event.detail).foregroundColor(plain ? .white : quiet)
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ToolGlyph(kind: event.kind, mood: mood, size: 15, playful: playful)
                Text(event.title).foregroundStyle(titleColor).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: state.hasNotch ? max(0, state.leftWingWidth(for: event.style) - 13) : .infinity)
            if state.hasNotch { Spacer().frame(width: state.notchWidth) } else { Spacer(minLength: 16) }
            HStack(spacing: 5) {
                Spacer(minLength: 0)
                if state.rightWingWidth(for: event.style) >= IslandState.glyphOnlyWidth {
                    detail.lineLimit(1)
                }
                if event.style == .connected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(Brand.good)
                }
            }
            .frame(maxWidth: state.hasNotch ? max(0, state.rightWingWidth(for: event.style) - 13) : .infinity)
        }
        .padding(.horizontal, 13)
        .font(.system(size: 12.5, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Nothing connected

/// The notch plus two 30pt wings: a dashed tile and a plus, no text.
struct EmptyCompactView: View {
    @ObservedObject var state: IslandState

    var body: some View {
        HStack(spacing: state.hasNotch ? 0 : 16) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [2]))
                .frame(width: 14, height: 14)
            if state.hasNotch { Spacer().frame(width: state.notchWidth) }
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Hovering the empty island: what Brim does and how to connect a tool.
struct EmptyPanel: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: IslandState
    let openSettings: () -> Void

    private static let kinds: [ToolKind] = [.claude, .codex, .copilot, .cursor, .windsurf, .openrouter]

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Self.kinds) { kind in
                    ToolGlyph(kind: kind, mood: .dim, size: 14, playful: false)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.08)))
                }
            }
            Text("Connect your AIs")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
            Text("See tokens and plan limits for each tool, right here.")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                PillButton(title: "Connect…", filled: true, action: openSettings)
                PillButton(title: "Hide until connected", filled: false) { settings.emptyIsland = .hidden }
            }
        }
        .foregroundStyle(.white)
        .padding(.top, state.hasNotch ? 46 : 40)
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
    }
}

struct PillButton: View {
    let title: String
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(filled ? Color.white : Color.white.opacity(0.12)))
                .foregroundStyle(filled ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
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
            Color.clear.frame(height: (state.hasNotch ? 44 : 40) - 10)

            HStack(spacing: 5) {
                Text("Today").foregroundStyle(.white.opacity(0.6))
                Text("·").foregroundStyle(.white.opacity(0.35))
                RollingText(text: "\(Format.tokens(model.snapshot.todayTokens)) tokens")
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

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                        ToolCard(tool: tool, model: model, openSettings: openSettings)
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
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
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
                ProblemRow(message: message, openSettings: openSettings)
            } else if tool.hasTokenData {
                tokenDetails
            } else {
                accountDetails
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private var isAccount: Bool { tool.kind.source == .account }

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
            Text("\(tool.todaySessions) sessions · \(tool.todayRequests) req")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
        }
        .monospacedDigit()

        if model.isWorking(tool) {
            WorkingLine(tint: tool.kind.tint)
        }

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
            ProblemRow(message: message, openSettings: openSettings)
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
    let message: String
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.attention)
            Text(message)
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: openSettings) {
                Text("Sign in")
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
                Text(window.detail ?? Format.percent(window.usedPercent))
                    .foregroundStyle(window.usedPercent >= 80 ? PlanBar.color(for: window.usedPercent) : .white)
                if let reset = window.resetsAt {
                    Text("· resets in \(Format.countdown(to: reset))").foregroundStyle(.white.opacity(0.35))
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
            Text(window.detail ?? Format.percent(window.usedPercent))
                .foregroundStyle(window.usedPercent >= 80 ? Self.color(for: window.usedPercent) : .white.opacity(0.6))
                .lineLimit(1)
                .frame(minWidth: 34, alignment: .trailing)
            Text(window.resetsAt.map { "resets \(Format.countdown(to: $0))" } ?? "")
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

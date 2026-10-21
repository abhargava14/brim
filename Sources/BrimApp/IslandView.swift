import IslandCore
import SwiftUI

// MARK: - Root

struct IslandView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: IslandState
    let openSettings: () -> Void
    let addAccount: (AddAccountRequest) -> Void

    private var cornerRadius: CGFloat { state.isExpanded ? (state.isEmpty ? 22 : 28) : (state.hasNotch ? 14 : 16) }
    private var width: CGFloat {
        state.isExpanded ? state.expandedWidth : state.compactWidth(for: model.event?.style)
    }

    var body: some View {
        ZStack(alignment: .top) {
            island
                .offset(x: state.isExpanded ? 0 : state.xOffset(for: model.event?.style))
            if settings.pendingIslandTip, !state.isExpanded, !state.steppedAside {
                IslandTipView { settings.pendingIslandTip = false }
                    .padding(.top, state.barHeight + 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: IslandController.canvas.width, height: IslandController.canvas.height, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onAppear { syncExpandedGeometry() }
        .onChange(of: state.isExpanded) { expanded in
            if expanded, settings.pendingIslandTip { settings.pendingIslandTip = false }
            syncExpandedGeometry()
        }
        .onChange(of: model.featuredTools.count) { _ in syncExpandedGeometry() }
        .onChange(of: settings.expandedLayout) { _ in syncExpandedGeometry() }
    }

    private func syncExpandedGeometry() {
        state.expandedToolCount = model.featuredTools.count
        state.expandedLayoutIsStrip = settings.expandedLayout == .strip
    }

    private var island: some View {
        ZStack(alignment: .top) {
            if state.isExpanded && state.isEmpty {
                EmptyPanel(settings: settings, state: state, addAccount: addAccount)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else if state.isExpanded {
                ExpandedView(model: model, settings: settings, state: state, openSettings: openSettings, addAccount: addAccount)
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

/// One-time tip under the island after first run (G44).
struct IslandTipView: View {
    let dismiss: () -> Void
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Brim lives here")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.primary)
            Text("Your connections take turns in the notch. Hover to expand, or press ⌥⌘B.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Got it", action: dismiss)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
        )
        .environment(\.colorScheme, .light)
        .onAppear {
            task = Task {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !Task.isCancelled else { return }
                dismiss()
            }
        }
        .onDisappear { task?.cancel() }
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
    /// Attention hop (-3pt). Off in compact wings so glyph + value stay on one centerline.
    var bounce = true
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
        guard animated, bounce else { return 0 }
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


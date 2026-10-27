import AppKit
import IslandCore
import SwiftUI

// Shared building blocks for the open island's tabs: theme, cards, pills, banners and charts.
// Sizes and opacities follow the Brim Island design (white text at 100/60/45/35%).

// MARK: - Theme

/// Colours of the open island. The closed notch is always black.
struct IslandTheme: Equatable {
    var fg: Color
    var bg: Color
    /// Popovers floating over the island.
    var pop: Color
    var isDark: Bool

    /// The foreground at an opacity, the design's `rgba(var(--f), x)`.
    func f(_ opacity: Double) -> Color { fg.opacity(opacity) }

    static let dark = IslandTheme(fg: .white, bg: .black, pop: Color(white: 0.11), isDark: true)
    static let light = IslandTheme(fg: Color(red: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255),
                                   bg: Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF5 / 255),
                                   pop: .white, isDark: false)

    static func resolve(_ appearance: IslandAppearance) -> IslandTheme {
        switch appearance {
        case .dark: return .dark
        case .light: return .light
        case .system:
            let dark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua
            return dark ? .dark : .light
        }
    }
}

private struct IslandThemeKey: EnvironmentKey {
    static let defaultValue = IslandTheme.dark
}

private struct TabPresetKey: EnvironmentKey {
    static let defaultValue: [String: String] = [:]
}

extension EnvironmentValues {
    var islandTheme: IslandTheme {
        get { self[IslandThemeKey.self] }
        set { self[IslandThemeKey.self] = newValue }
    }

    /// Starting state for a tab's inner screens ("ai.selected": id), used by snapshot renders.
    var tabPreset: [String: String] {
        get { self[TabPresetKey.self] }
        set { self[TabPresetKey.self] = newValue }
    }
}

/// Colours the design uses for one meaning each.
enum Palette {
    static let green = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
    static let amber = Brand.attention
    static let red = Brand.limit
    static let blue = Color(red: 0x0A / 255, green: 0x84 / 255, blue: 1)
    static let cyan = Color(red: 0x64 / 255, green: 0xD2 / 255, blue: 1)
    static let purple = Color(red: 0xBF / 255, green: 0x5A / 255, blue: 0xF2 / 255)
    static let yellow = Color(red: 1, green: 0xD6 / 255, blue: 0x0A / 255)
    static let coral = Color(red: 1, green: 0x6B / 255, blue: 0x4A / 255)

    /// Plan bars: the foreground (nil) until 80%, then amber, then red at 100%.
    /// Colour only appears when a limit needs attention.
    static func fuel(_ percent: Double) -> Color? {
        percent >= 100 ? red : percent >= 80 ? amber : nil
    }

    /// Amber or red text only when a value needs attention; otherwise nil (use the foreground).
    static func warm(_ percent: Double) -> Color? {
        percent >= 100 ? red : percent >= 80 ? amber : nil
    }
}

extension Font {
    /// SF Pro Rounded at the design's weights (800 → heavy, 700 → bold).
    static func brim(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension TabID {
    /// SF Symbol for the tab bar, header and Settings.
    var symbol: String {
        switch self {
        case .home: return "house"
        case .ai: return "sparkle"
        case .analytics: return "chart.bar"
        case .notes: return "note.text"
        case .calendar: return "calendar"
        case .timers: return "timer"
        case .clocks: return "globe"
        case .stats: return "cpu"
        case .screen: return "hourglass"
        case .weather: return "cloud.sun"
        case .links: return "bookmark"
        case .sounds: return "waveform"
        case .scratchpad: return "square.and.pencil"
        case .clipboard: return "doc.on.clipboard"
        case .files: return "wand.and.stars"
        case .units: return "arrow.left.arrow.right"
        }
    }
}

// MARK: - Cards and labels

/// The rounded card every tab is built from (design v2 · radius 18, padding 12 × 14).
struct IslandCard<Content: View>: View {
    var padding = EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
    var radius: CGFloat = 18
    var tint: Color?
    @ViewBuilder var content: Content
    @Environment(\.islandTheme) private var theme

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tint ?? theme.f(0.06)))
    }
}

/// Small spaced capitals above a card's content ("NOW PLAYING").
struct SectionTitle: View {
    let title: String
    var aside: String?
    var opacity = 0.6
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.brim(10.5))
                .kerning(1.26)
                .foregroundStyle(theme.f(opacity))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let aside {
                Text(aside)
                    .font(.brim(11, .bold))
                    .foregroundStyle(theme.f(0.35))
                    .lineLimit(1)
            }
        }
    }
}

/// A hover highlight for clickable rows and tiles.
struct HoverFill: ViewModifier {
    var radius: CGFloat
    var base: Color = .clear
    var hover: Color
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(hovering ? hover : base))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverFill(_ radius: CGFloat, base: Color = .clear, hover: Color) -> some View {
        modifier(HoverFill(radius: radius, base: base, hover: hover))
    }

    /// A plain tap target with the button trait, for custom-drawn controls.
    func onClick(label: String? = nil, perform action: @escaping () -> Void) -> some View {
        self
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label.map { Text($0) } ?? Text(""))
    }
}

// MARK: - Buttons and pills

/// A capsule button: primary (inverted), secondary (subtle) or tinted.
struct IslandButton: View {
    enum Style { case primary, secondary, tint(Color), destructive }

    let title: String
    var sub: String?
    var style: Style = .secondary
    var height: CGFloat = 30
    var fontSize: CGFloat = 12
    var symbol: String?
    let action: () -> Void
    @Environment(\.islandTheme) private var theme
    @State private var hovering = false

    private var colors: (Color, Color) {
        switch style {
        case .primary: return (theme.fg, theme.bg)
        case .secondary: return (theme.f(hovering ? 0.2 : 0.12), theme.fg)
        case .tint(let color): return (color, .black)
        case .destructive: return (Palette.red.opacity(0.14), Palette.red)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: fontSize - 1, weight: .bold))
                }
                Text(title).font(.brim(fontSize))
                if let sub {
                    Text(sub).font(.brim(fontSize - 1, .bold)).opacity(0.6)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, height * 0.46)
            .frame(height: height)
            .foregroundStyle(colors.1)
            .background(Capsule().fill(colors.0))
            .opacity(hovering && !isSecondary ? 0.88 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var isSecondary: Bool {
        if case .secondary = style { return true }
        return false
    }
}

/// A round icon button (refresh, add, settings).
struct IconButton: View {
    let symbol: String
    var help: String
    var size: CGFloat = 26
    var active = false
    var rotation: Double = 0
    let action: () -> Void
    @Environment(\.islandTheme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .bold))
                .rotationEffect(.degrees(rotation))
                .frame(width: size, height: size)
                .foregroundStyle(active ? theme.bg : theme.fg)
                .background(Circle().fill(active ? theme.fg : theme.f(hovering ? 0.18 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Segmented pills ("Today · 7 days · 30 days").
struct SegmentedPills<Value: Hashable>: View {
    enum Look {
        /// Active pill is inverted (white on black).
        case strong
        /// Active pill is a light tint.
        case soft
    }

    let options: [(Value, String)]
    @Binding var selection: Value
    var look: Look = .soft
    var height: CGFloat = 26
    var dot: ((Value) -> Color?)?
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let on = value == selection
                HStack(spacing: 6) {
                    Text(label).font(.brim(height >= 26 ? 12 : 11.5))
                    if let color = dot?(value) {
                        Circle().fill(color).frame(width: 5, height: 5)
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(height: height)
                .foregroundStyle(on ? (look == .strong ? theme.bg : theme.fg) : theme.f(0.6))
                .background(Capsule().fill(on ? (look == .strong ? theme.fg : theme.f(0.16)) : .clear))
                .contentShape(Capsule())
                .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { selection = value } }
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                .accessibilityLabel(label)
            }
        }
        .padding(2)
        .background(Capsule().fill(theme.f(0.06)))
    }
}

/// A small switch drawn like the design's (green when on).
struct IslandSwitch: View {
    @Binding var isOn: Bool
    var label: String
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Capsule()
            .fill(isOn ? theme.fg : theme.f(0.2))
            .frame(width: 30, height: 18)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(isOn ? theme.bg : .white).frame(width: 14, height: 14).padding(2)
            }
            .onTapGesture { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { isOn.toggle() } }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - States

/// What a tab shows when it can't show anything yet: not connected, or permission off.
struct ConnectCard: View {
    struct Action {
        let title: String
        var sub: String?
        var primary = true
        let run: () -> Void
    }

    let symbol: String
    let color: Color
    let title: String
    let message: String
    var actions: [Action] = []
    var waiting: String?
    var note: String?
    @Environment(\.islandTheme) private var theme

    /// Only warnings keep their colour; everything else is monochrome.
    private var tint: Color? { color == Palette.amber || color == Palette.red ? color : nil }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint ?? theme.fg)
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tint?.opacity(0.16) ?? theme.f(0.1)))
                .padding(.bottom, 4)
            Text(title).font(.brim(18))
            Text(message)
                .font(.brim(13, .bold))
                .foregroundStyle(theme.f(0.6))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if !actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                        IslandButton(title: action.title, sub: action.sub, style: action.primary ? .primary : .secondary,
                                     height: 34, fontSize: 13, action: action.run)
                    }
                }
                .padding(.top, 6)
            }
            if let waiting {
                HStack(spacing: 8) {
                    Spinner(size: 12)
                    Text(waiting).font(.brim(12)).foregroundStyle(theme.f(0.6))
                }
            }
            if let note {
                Text(note)
                    .font(.brim(11.5, .bold))
                    .foregroundStyle(theme.f(0.42))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 460)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.f(0.06)))
    }
}

/// A one-line banner when data is stale but still useful (offline, revoked key).
struct WarnBanner: View {
    let title: String
    let message: String
    var button: String?
    var color: Color = Palette.amber
    var action: (() -> Void)?
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.brim(12)).foregroundStyle(color).fixedSize()
            Text(message).font(.brim(12, .bold)).foregroundStyle(theme.f(0.65)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if let button, let action {
                IslandButton(title: button, height: 24, fontSize: 11.5, action: action)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.12)))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// A small circular progress spinner.
struct Spinner: View {
    var size: CGFloat = 12
    var line: CGFloat = 2
    @State private var spin = false
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(theme.fg, style: StrokeStyle(lineWidth: line, lineCap: .round))
            .background(Circle().stroke(theme.f(0.2), lineWidth: line))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true } }
    }
}

// MARK: - Numbers

/// One cell of a stat strip: label, big value, small line.
struct StatItem: Identifiable {
    let id = UUID()
    let key: String
    let value: String
    var sub: String = ""
    var valueColor: Color?
    var subColor: Color?
}

/// Four (or so) stats in a row with hairline dividers, like the design's stat strips.
struct StatStrip: View {
    let items: [StatItem]
    /// Fixed value size; nil shrinks long values (26 / 22 / 19pt).
    var valueSize: CGFloat?
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.key.uppercased())
                        .font(.brim(10))
                        .kerning(1.2)
                        .foregroundStyle(theme.f(0.45))
                    Text(item.value)
                        .font(.brim(valueSize ?? size(for: item.value)))
                        .foregroundStyle(item.valueColor ?? theme.fg)
                        .frame(height: 30, alignment: .leading)
                        .monospacedDigit()
                    Text(item.sub)
                        .font(.brim(11, .bold))
                        .foregroundStyle(item.subColor ?? theme.f(0.45))
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    if index > 0 { Rectangle().fill(theme.f(0.09)).frame(width: 1) }
                }
            }
        }
    }

    private func size(for value: String) -> CGFloat {
        value.count > 7 ? 19 : value.count > 5 ? 22 : 26
    }
}

/// A key–value row in a card ("Plan · Max 5×").
struct DetailRow: View {
    let key: String
    let value: String
    var valueColor: Color?
    var height: CGFloat = 30
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Text(key).foregroundStyle(theme.f(0.7))
            Spacer(minLength: 6)
            Text(value).font(.brim(12.5)).foregroundStyle(valueColor ?? theme.fg)
        }
        .font(.brim(12.5, .bold))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(minHeight: height)
    }
}

/// A thin rounded progress bar.
struct MiniBar: View {
    let fraction: Double
    var color: Color?
    var height: CGFloat = 5
    @Environment(\.islandTheme) private var theme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.f(0.1))
                Capsule().fill(color ?? theme.fg)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

/// A list row with a bar behind it, sized by share (Top pages, Sources).
struct ShareRow: View {
    let label: String
    let value: String
    let fraction: Double
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack {
            Text(label).font(.brim(12, .bold)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(value).font(.brim(12)).monospacedDigit()
        }
        .padding(.horizontal, 8)
        .frame(height: 25)
        .background(alignment: .leading) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(theme.f(0.08))
                    .frame(width: max(18, geo.size.width * max(0, min(1, fraction))))
            }
        }
    }
}

// MARK: - Charts

/// A smooth line through values (Catmull-Rom), with an optional soft area under it.
struct CurveChart: View {
    let values: [Double]
    var color: Color?
    var fill = true
    var endDot = false
    var lineWidth: CGFloat = 2.2
    var padding: CGFloat = 8
    @Environment(\.islandTheme) private var theme

    var body: some View {
        GeometryReader { geo in
            let points = Self.points(values, in: geo.size, pad: padding)
            let tint = color ?? theme.fg
            ZStack(alignment: .topLeading) {
                if fill, points.count > 1 {
                    Self.curve(points).area(width: geo.size.width, height: geo.size.height)
                        .fill(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                }
                if points.count > 1 {
                    Self.curve(points)
                        .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                }
                if endDot, let last = points.last {
                    Circle().fill(tint).frame(width: 7, height: 7).position(last)
                }
            }
        }
    }

    static func points(_ values: [Double], in size: CGSize, pad: CGFloat) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let top = max(values.max() ?? 0, 0.001)
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            CGPoint(x: CGFloat(index) * step, y: size.height - pad - CGFloat(value / top) * (size.height - 2 * pad))
        }
    }

    static func curve(_ p: [CGPoint]) -> CurvePath { CurvePath(points: p) }

    struct CurvePath: Shape {
        let points: [CGPoint]

        func path(in rect: CGRect) -> Path {
            var path = Path()
            guard let first = points.first else { return path }
            path.move(to: first)
            for i in 0..<(points.count - 1) {
                let a = i > 0 ? points[i - 1] : points[i]
                let b = points[i], c = points[i + 1]
                let e = i + 2 < points.count ? points[i + 2] : c
                path.addCurve(to: c,
                              control1: CGPoint(x: b.x + (c.x - a.x) / 6, y: b.y + (c.y - a.y) / 6),
                              control2: CGPoint(x: c.x - (e.x - b.x) / 6, y: c.y - (e.y - b.y) / 6))
            }
            return path
        }

        func area(width: CGFloat, height: CGFloat) -> Path {
            var path = self.path(in: .zero)
            path.addLine(to: CGPoint(x: width, y: height))
            path.addLine(to: CGPoint(x: 0, y: height))
            path.closeSubpath()
            return path
        }
    }
}

/// Simple vertical bars (screen time hours, week).
struct BarColumns: View {
    struct Bar: Identifiable {
        let id = UUID()
        let value: Double
        var label: String = ""
        var highlight = false
    }

    let bars: [Bar]
    var spacing: CGFloat = 6
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let top = max(bars.map(\.value).max() ?? 0, 0.001)
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(bars) { bar in
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        VStack {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(bar.highlight ? theme.fg : theme.f(0.35))
                                .frame(height: max(3, geo.size.height * bar.value / top))
                        }
                    }
                    Text(bar.label).font(.brim(10, .bold)).foregroundStyle(theme.f(0.4)).frame(height: 12)
                }
            }
        }
    }
}

// MARK: - Scrolling

/// A ScrollView in the app; plain clipped content in snapshot renders, which can't draw scroll views.
struct IslandScroll<Content: View>: View {
    var axis: Axis.Set = .vertical
    @ViewBuilder var content: Content

    var body: some View {
        if AppSettings.isSnapshot, axis == .horizontal {
            HStack(spacing: 0) { content }
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
        } else if AppSettings.isSnapshot {
            GeometryReader { geo in
                Group {
                    if axis == .horizontal {
                        HStack(spacing: 0) { content }
                    } else {
                        VStack(spacing: 0) { content }
                    }
                }
                .frame(width: axis == .horizontal ? nil : geo.size.width, height: axis == .horizontal ? geo.size.height : nil, alignment: .topLeading)
            }
            .clipped()
        } else {
            ScrollView(axis, showsIndicators: false) { content }
        }
    }
}

// MARK: - Inputs

/// A thin slider drawn like the design's (the native one can't take the island's colours).
struct IslandSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var tint: Color?
    var label: String
    @Environment(\.islandTheme) private var theme

    var body: some View {
        GeometryReader { geo in
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule().fill(theme.f(0.14)).frame(height: 4)
                Capsule().fill(tint ?? theme.fg).frame(width: max(4, geo.size.width * fraction), height: 4)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .frame(width: 14, height: 14)
                    .offset(x: max(0, min(geo.size.width - 14, geo.size.width * fraction - 7)))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let f = max(0, min(1, drag.location.x / max(geo.size.width, 1)))
                value = range.lowerBound + f * (range.upperBound - range.lowerBound)
            })
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(((value - range.lowerBound) / (range.upperBound - range.lowerBound)) * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 10
            value = min(range.upperBound, max(range.lowerBound, value + (direction == .increment ? step : -step)))
        }
    }
}

/// A rounded search / text field in the island's style.
struct IslandField: View {
    let placeholder: String
    @Binding var text: String
    var symbol: String?
    var height: CGFloat = 30
    var fontSize: CGFloat = 12.5
    var onSubmit: () -> Void = {}
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: fontSize, weight: .semibold)).opacity(0.6)
            }
            PlainTextField(placeholder, text: $text, font: .brim(fontSize, .bold), onSubmit: onSubmit)
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: height * 0.34, style: .continuous).fill(theme.f(0.07)))
    }
}

/// A plain text field; snapshot renders draw its text instead (they can't draw AppKit fields).
struct PlainTextField: View {
    let placeholder: String
    @Binding var text: String
    var font: Font = .brim(12.5, .bold)
    var onSubmit: () -> Void = {}
    @Environment(\.islandTheme) private var theme

    init(_ placeholder: String, text: Binding<String>, font: Font = .brim(12.5, .bold), onSubmit: @escaping () -> Void = {}) {
        self.placeholder = placeholder
        _text = text
        self.font = font
        self.onSubmit = onSubmit
    }

    var body: some View {
        if AppSettings.isSnapshot {
            Text(text.isEmpty ? placeholder : text)
                .font(font)
                .foregroundStyle(text.isEmpty ? theme.f(0.35) : theme.fg)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(font)
                .onSubmit(onSubmit)
        }
    }
}

// MARK: - Layout

/// Columns that share the width by weight, like CSS `1.3fr 1fr 1fr`.
struct WeightedColumns: Layout {
    var weights: [CGFloat]
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let widths = columnWidths(total: width, count: subviews.count)
        let height = proposal.height ?? subviews.enumerated().map { index, view in
            view.sizeThatFits(ProposedViewSize(width: widths[index], height: nil)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(total: bounds.width, count: subviews.count)
        var x = bounds.minX
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: widths[index], height: bounds.height))
            x += widths[index] + spacing
        }
    }

    private func columnWidths(total: CGFloat, count: Int) -> [CGFloat] {
        let used = (0..<count).map { $0 < weights.count ? weights[$0] : 1 }
        let sum = used.reduce(0, +)
        let free = max(0, total - spacing * CGFloat(max(count - 1, 0)))
        return used.map { free * $0 / max(sum, 0.001) }
    }
}

extension View {
    /// Accepts dropped files; skipped in snapshot renders, which can't draw drop targets.
    @ViewBuilder
    func fileDrop(isTargeted: Binding<Bool>, perform: @escaping ([NSItemProvider]) -> Bool) -> some View {
        if AppSettings.isSnapshot {
            self
        } else {
            onDrop(of: [.fileURL], isTargeted: isTargeted, perform: perform)
        }
    }
}

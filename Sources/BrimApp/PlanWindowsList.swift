import IslandCore
import SwiftUI

/// Lists **every** plan / model window for a connection — never collapses to the tightest alone.
/// Cursor dual pools, Claude Fable + Week · all models, etc. always appear together with “used”.
struct PlanWindowsList: View {
    let windows: [PlanWindow]
    var kind: ToolKind? = nil
    /// Compact row (Overview / Connections) vs island chrome.
    var style: Style = .app
    /// When true, each window gets a thin fuel bar (expanded Cards).
    var showBars: Bool = false

    enum Style {
        case app
        case island
        case strip
    }

    var body: some View {
        if windows.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: style == .strip ? .center : .leading, spacing: style == .strip ? 4 : 6) {
                ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                    row(window)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ window: PlanWindow) -> some View {
        let label = Format.windowLabel(window, kind: kind)
        let used = Format.used(window)
        let hot = window.usedPercent >= 80
        let color: Color = {
            switch style {
            case .app: return hot ? Color.orange : BrimChrome.ink
            case .island, .strip: return hot ? PlanBar.color(for: window.usedPercent) : .white
            }
        }()
        let muted: Color = {
            switch style {
            case .app: return BrimChrome.muted
            case .island, .strip: return .white.opacity(0.6)
            }
        }()

        switch style {
        case .strip:
            VStack(spacing: 1) {
                Text(label)
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(used)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
        case .app, .island:
            VStack(alignment: .leading, spacing: showBars ? 4 : 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(label)
                        .font(style == .app ? BrimChrome.caption : .system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(used)
                        .font(style == .app
                              ? .system(size: 12, weight: .heavy, design: .rounded)
                              : .system(size: 12.5, weight: .heavy, design: .rounded))
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .monospacedDigit()
                }
                if showBars {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(style == .app ? 0.08 : 0.1))
                            Capsule()
                                .fill(PlanBar.color(for: window.usedPercent))
                                .frame(width: max(3, geo.size.width * min(window.usedPercent, 100) / 100))
                        }
                    }
                    .frame(height: style == .app ? 4 : 5)
                }
            }
        }
    }
}

extension ToolSnapshot {
    /// Plan windows to show in detail surfaces — every reported window, in API order.
    var displayPlanWindows: [PlanWindow] { planWindows }
}

/// One plan window as a labelled bar with its use and reset.
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

import IslandCore
import SwiftUI

// MARK: - Compact

/// Default notch view: one connection at a time (glyph + primary metric). Hover/click expands for detail.
struct CompactView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var state: IslandState

    /// When several tools are connected, they take turns in the left wing.
    private static let pageSeconds: Double = 6

    var body: some View {
        let tools = model.featuredTools
        TimelineView(.periodic(from: .now, by: Self.pageSeconds)) { context in
            let pages = max(1, tools.count)
            let page = Int(context.date.timeIntervalSince1970 / Self.pageSeconds) % pages
            let tool = tools.isEmpty ? nil : tools[page]
            content(tool, page: page, pages: pages)
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
    private func content(_ tool: ToolSnapshot?, page: Int, pages: Int) -> some View {
        HStack(spacing: state.hasNotch ? 0 : 12) {
            wing(tool, alignment: .leading)
            if state.hasNotch {
                Spacer().frame(width: state.notchWidth)
            }
            // Quiet right wing by default — no second tool, no token totals. Expand for detail.
            quietWing
        }
        .padding(.horizontal, 4)
        .font(.system(size: 12, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if pages > 1 {
                PageDots(count: pages, current: page).padding(.bottom, 3)
            }
        }
    }

    /// Shared height so left and right wing glyphs + values sit on one centerline.
    private static let wingLineHeight: CGFloat = 16

    private func mood(_ tool: ToolSnapshot) -> GlyphMood {
        if tool.statusMessage != nil && !tool.hasData { return .dim }
        if (tool.tightestWindow?.usedPercent ?? 0) >= 95 { return .attention }
        return model.isWorking(tool) ? .working : .idle
    }

    private func wing(_ tool: ToolSnapshot?, alignment: HorizontalAlignment) -> some View {
        let density = wingDensity(alignment)
        return HStack(alignment: .center, spacing: 3) {
            if let tool {
                if alignment == .trailing { Spacer(minLength: 0) }
                // No playful bounce in wings — attention's -3pt hop misaligned left/right.
                ToolGlyph(kind: tool.kind, mood: mood(tool), size: 12, playful: false, name: tool.name)
                    .frame(width: 14, height: Self.wingLineHeight, alignment: .center)
                if density != .iconOnly {
                    RollingText(text: model.compactValue(for: tool))
                        .foregroundStyle(valueColor(tool))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(height: Self.wingLineHeight, alignment: .center)
                        .layoutPriority(1)
                    // Suffixes ("used", short names) only when the wing is wide enough — rare at idle 48pt.
                    if density == .full, let suffix = model.wingSuffix(for: tool) {
                        Suffix(text: suffix)
                            .frame(height: Self.wingLineHeight, alignment: .center)
                    }
                }
                if alignment == .leading { Spacer(minLength: 0) }
            } else {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                    .frame(height: Self.wingLineHeight)
                if density != .iconOnly {
                    Text("Connect").foregroundStyle(.secondary)
                        .frame(height: Self.wingLineHeight)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: wingWidth(alignment), maxHeight: .infinity, alignment: .center)
    }

    /// Empty right wing keeps the notch balanced without adding a second row of chrome.
    private var quietWing: some View {
        Color.clear
            .frame(maxWidth: wingWidth(.trailing), maxHeight: .infinity)
    }

    private func wingDensity(_ alignment: HorizontalAlignment) -> WingDensity {
        let width = alignment == .leading ? state.leftWingWidth(for: nil) : state.rightWingWidth(for: nil)
        return state.density(for: width)
    }

    private func wingWidth(_ alignment: HorizontalAlignment) -> CGFloat {
        guard state.hasNotch else { return .infinity }
        let wing = alignment == .leading ? state.leftWingWidth(for: nil) : state.rightWingWidth(for: nil)
        return max(0, wing - 2)
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
        HStack(spacing: 3) {
            ForEach(0..<min(count, 6), id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(index == current ? 0.85 : 0.22))
                    .frame(width: 3, height: 3)
            }
        }
    }
}

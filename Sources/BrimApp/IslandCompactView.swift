import IslandCore
import SwiftUI

// MARK: - Compact

/// Notch view: connections take turns in pairs (left + right wing), matching design v2.
struct CompactView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var state: IslandState

    /// Design v2 carousel: a new pair every 4s.
    private static let pageSeconds: Double = 4

    var body: some View {
        let tools = model.featuredTools
        let pages = Self.pages(from: tools, todayTotal: model.snapshot.todayTokens)
        TimelineView(.periodic(from: .now, by: Self.pageSeconds)) { context in
            let pageCount = max(1, pages.count)
            let page = Int(context.date.timeIntervalSince1970 / Self.pageSeconds) % pageCount
            let pair = pages.isEmpty ? (nil, nil) : pages[page]
            content(left: pair.0, right: pair.1, page: page, pages: pageCount)
        }
        .clipped()
    }

    /// Pairs for the carousel. Odd last page puts today's total on the right (design v2).
    private static func pages(from tools: [ToolSnapshot], todayTotal: Int64) -> [(ToolSnapshot?, CompactWingValue?)] {
        guard !tools.isEmpty else { return [(nil, nil)] }
        if tools.count == 1 {
            let tool = tools[0]
            return [(tool, .tokensToday(todayTotal))]
        }
        var result: [(ToolSnapshot?, CompactWingValue?)] = []
        var index = 0
        while index < tools.count {
            let left = tools[index]
            if index + 1 < tools.count {
                result.append((left, .tool(tools[index + 1])))
            } else {
                result.append((left, .tokensToday(todayTotal)))
            }
            index += 2
        }
        return result
    }

    /// Design v2 page change: out rises 13pt / fades 280ms; in rises from below over ~460ms.
    private static let pageIn = AnyTransition.asymmetric(
        insertion: .offset(y: 13).combined(with: .opacity),
        removal: .offset(y: -13).combined(with: .opacity)
    )

    @ViewBuilder
    private func content(left: ToolSnapshot?, right: CompactWingValue?, page: Int, pages: Int) -> some View {
        HStack(spacing: state.hasNotch ? 0 : 12) {
            wing(tool: left, alignment: .leading)
                .id("L-\(page)-\(left?.id ?? "∅")")
                .transition(Self.pageIn)
                .animation(.spring(response: 0.46, dampingFraction: 0.8), value: page)
            if state.hasNotch {
                Spacer().frame(width: state.notchWidth)
            }
            rightWing(right)
                .id("R-\(page)")
                .transition(Self.pageIn)
                // Right wing lags 60ms (design v2).
                .animation(.spring(response: 0.46, dampingFraction: 0.8).delay(0.06), value: page)
        }
        .padding(.horizontal, 4)
        .font(.system(size: 12.5, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if pages > 1 {
                PageDots(count: pages, current: page).padding(.bottom, 6)
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

    private func wing(tool: ToolSnapshot?, alignment: HorizontalAlignment) -> some View {
        let density = wingDensity(alignment)
        return HStack(alignment: .center, spacing: 6) {
            if let tool {
                if alignment == .trailing { Spacer(minLength: 0) }
                ToolGlyph(kind: tool.kind, mood: mood(tool), size: 14, playful: model.settings.playful, bounce: false, name: tool.name)
                    .frame(width: 14, height: Self.wingLineHeight, alignment: .center)
                if density != .iconOnly {
                    RollingText(text: model.compactValue(for: tool))
                        .foregroundStyle(valueColor(tool))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(height: Self.wingLineHeight, alignment: .center)
                        .layoutPriority(1)
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

    @ViewBuilder
    private func rightWing(_ value: CompactWingValue?) -> some View {
        switch value {
        case .none:
            Color.clear
                .frame(maxWidth: wingWidth(.trailing), maxHeight: .infinity)
        case .tool(let tool):
            wing(tool: tool, alignment: .trailing)
        case .tokensToday(let total):
            let density = wingDensity(.trailing)
            HStack(alignment: .center, spacing: 4) {
                Spacer(minLength: 0)
                if density != .iconOnly {
                    RollingText(text: Format.tokens(total))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .frame(height: Self.wingLineHeight, alignment: .center)
                    if density == .full {
                        Suffix(text: "today")
                            .frame(height: Self.wingLineHeight, alignment: .center)
                    }
                }
            }
            .frame(maxWidth: wingWidth(.trailing), maxHeight: .infinity, alignment: .center)
        }
    }

    private enum CompactWingValue {
        case tool(ToolSnapshot)
        case tokensToday(Int64)
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
        HStack(spacing: 4) {
            ForEach(0..<min(count, 8), id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(index == current ? 1 : 0.3))
                    .frame(width: 4, height: 4)
            }
        }
    }
}

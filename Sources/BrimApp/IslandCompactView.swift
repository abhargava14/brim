import IslandCore
import SwiftUI

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
        HStack(spacing: state.hasNotch ? 0 : 12) {
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
        .padding(.horizontal, 4)
        .font(.system(size: 12, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if pages > 1 { PageDots(count: pages, current: page).padding(.bottom, 4) }
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

    private func wingDensity(_ alignment: HorizontalAlignment) -> WingDensity {
        let width = alignment == .leading ? state.leftWingWidth(for: nil) : state.rightWingWidth(for: nil)
        return state.density(for: width)
    }

    private func wingWidth(_ alignment: HorizontalAlignment) -> CGFloat {
        guard state.hasNotch else { return .infinity }
        let wing = alignment == .leading ? state.leftWingWidth(for: nil) : state.rightWingWidth(for: nil)
        return max(0, wing - 2)
    }

    /// With a single tool, the right wing shows today's tokens (or, for account tools, the
    /// tightest window when the left wing doesn't already show it).
    private func detailWing(_ tool: ToolSnapshot?) -> some View {
        let density = wingDensity(.trailing)
        return HStack(alignment: .center, spacing: 3) {
            Spacer(minLength: 0)
            if density == .iconOnly {
                EmptyView()
            } else if let tool, tool.hasTokenData {
                RollingText(text: Format.tokens(tool.today.total))
                    .frame(height: Self.wingLineHeight, alignment: .center)
                if density == .full { Suffix(text: "today").frame(height: Self.wingLineHeight) }
            } else if let tool, let window = tool.tightestWindow, model.compactValue(for: tool) != Format.percent(window.usedPercent) {
                Text("\(window.label) \(Format.percent(window.usedPercent))")
                    .foregroundStyle(valueColor(tool))
                    .frame(height: Self.wingLineHeight, alignment: .center)
                if density == .full { Suffix(text: "used").frame(height: Self.wingLineHeight) }
            }
        }
        .lineLimit(1)
        .frame(maxWidth: wingWidth(.trailing), maxHeight: .infinity, alignment: .center)
    }

    /// The odd last page of the carousel: today's total across every connection.
    private var totalWing: some View {
        let density = wingDensity(.trailing)
        return HStack(alignment: .center, spacing: 3) {
            Spacer(minLength: 0)
            if density != .iconOnly {
                RollingText(text: Format.tokens(model.snapshot.todayTokens))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(height: Self.wingLineHeight, alignment: .center)
                if density == .full { Suffix(text: "today").frame(height: Self.wingLineHeight) }
            }
        }
        .lineLimit(1)
        .frame(maxWidth: wingWidth(.trailing), maxHeight: .infinity, alignment: .center)
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


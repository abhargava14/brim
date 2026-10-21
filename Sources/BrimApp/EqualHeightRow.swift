import SwiftUI

/// Horizontal row where every child shares the **tallest child’s ideal height**.
///
/// Uses `Layout` + `sizeThatFits(height: nil)` so `Spacer`s collapse during measurement.
/// PreferenceKey + `maxHeight: .infinity` inside a `ScrollView` was measuring the viewport
/// instead of content, which stretched island cards into empty skyscrapers.
struct EqualHeightHStack: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let sizes = idealSizes(subviews: subviews, proposal: proposal)
        let width = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1))
        let height = sizes.map(\.height).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideals = idealSizes(subviews: subviews, proposal: proposal)
        var x = bounds.minX
        for (sub, ideal) in zip(subviews, ideals) {
            sub.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: ideal.width, height: bounds.height)
            )
            x += ideal.width + spacing
        }
    }

    /// Ideal sizes with spacers collapsed (`height: nil`). Fixed-width island cards keep their
    /// width; flexible Overview columns share the proposed width evenly.
    private func idealSizes(subviews: Subviews, proposal: ProposedViewSize) -> [CGSize] {
        let count = CGFloat(subviews.count)
        let spacingTotal = spacing * CGFloat(max(0, subviews.count - 1))
        let unconstrained = subviews.map { $0.sizeThatFits(.unspecified) }

        if let total = proposal.width, total.isFinite, total > 0, count > 0 {
            let naturalSum = unconstrained.map(\.width).reduce(0, +) + spacingTotal
            // Flexible children report tiny natural widths; distribute the row width evenly.
            if naturalSum < total * 0.85 {
                let share = max(0, (total - spacingTotal) / count)
                return subviews.map { $0.sizeThatFits(ProposedViewSize(width: share, height: nil)) }
            }
        }

        return zip(subviews, unconstrained).map { sub, ideal in
            let width = ideal.width > 0 ? ideal.width : nil
            return sub.sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
    }
}

/// Legacy PreferenceKey helpers (Overview migration / call sites). Prefer `EqualHeightHStack`.
struct EqualHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    func reportEqualHeight() -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: EqualHeightPreferenceKey.self, value: geo.size.height)
            }
        )
    }

    /// `minHeight` only — never lock `maxHeight` to a ScrollView viewport measurement.
    func fillEqualHeight(_ height: CGFloat, alignment: Alignment = .topLeading) -> some View {
        frame(minHeight: height > 0 ? height : nil, alignment: alignment)
    }
}

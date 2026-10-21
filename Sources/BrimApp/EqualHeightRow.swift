import SwiftUI

/// Shared equal-height row for Overview cards and the expanded island (Cards / Strip + Add).
/// Measures each child’s ideal height, then applies the max as `minHeight` so bottoms align.
struct EqualHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Reports this view’s height into an `EqualHeightPreferenceKey` group.
    func reportEqualHeight() -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: EqualHeightPreferenceKey.self, value: geo.size.height)
            }
        )
    }

    /// Stretches to a measured row height (no-op while height is still 0).
    /// Locks min and max so children with `maxHeight: .infinity` (and stroke backgrounds) fill edge-to-edge.
    func fillEqualHeight(_ height: CGFloat, alignment: Alignment = .topLeading) -> some View {
        frame(
            minHeight: height > 0 ? height : nil,
            maxHeight: height > 0 ? height : nil,
            alignment: alignment
        )
    }
}

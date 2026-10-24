import IslandCore
import SwiftUI

// MARK: - Nothing connected

/// The notch plus two small wings: a dashed tile and a plus, no text.
struct EmptyCompactView: View {
    @ObservedObject var state: IslandState

    var body: some View {
        HStack(spacing: state.hasNotch ? 0 : 12) {
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

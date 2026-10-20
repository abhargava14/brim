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

/// Hovering the empty island: what Brim does and how to connect a tool.
struct EmptyPanel: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: IslandState
    let addAccount: (AddAccountRequest) -> Void

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
                PillButton(title: "Add Account…", filled: true) { addAccount(AddAccountRequest()) }
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


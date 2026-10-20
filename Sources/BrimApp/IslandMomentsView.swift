import IslandCore
import SwiftUI

// MARK: - Event moments

struct EventView: View {
    let event: IslandEvent
    @ObservedObject var state: IslandState
    let playful: Bool

    private var mood: GlyphMood {
        switch event.style {
        case .connected, .milestone: return .celebrate
        case .warning, .limit: return .attention
        case .disconnected: return .dim
        }
    }

    private var titleColor: Color {
        switch event.style {
        case .connected, .milestone: return .white
        case .warning: return Brand.attention
        case .limit: return Brand.limit
        case .disconnected: return .white.opacity(0.6)
        }
    }

    /// "resets in 1h 20m": the lead-in is quiet, the time stands out.
    private var detail: Text {
        let quiet = Color.white.opacity(0.6)
        for lead in ["resets in ", "back in "] where event.detail.hasPrefix(lead) {
            return Text(lead).foregroundColor(quiet) + Text(event.detail.dropFirst(lead.count)).foregroundColor(.white)
        }
        let plain = event.style == .connected
        return Text(event.detail).foregroundColor(plain ? .white : quiet)
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ToolGlyph(kind: event.kind, mood: mood, size: 15, playful: playful)
                Text(event.title).foregroundStyle(titleColor).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: state.hasNotch ? max(0, state.leftWingWidth(for: event.style) - 8) : .infinity)
            if state.hasNotch { Spacer().frame(width: state.notchWidth) } else { Spacer(minLength: 12) }
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                if state.density(for: state.rightWingWidth(for: event.style)) != .iconOnly {
                    detail.lineLimit(1)
                }
                if event.style == .connected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(Brand.good)
                }
            }
            .frame(maxWidth: state.hasNotch ? max(0, state.rightWingWidth(for: event.style) - 8) : .infinity)
        }
        .padding(.horizontal, 8)
        .font(.system(size: 12.5, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .frame(maxHeight: .infinity)
    }
}


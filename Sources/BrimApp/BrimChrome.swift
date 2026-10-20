import AppKit
import SwiftUI

/// Shared dark Brim chrome — matches the Dynamic Island / Add Connection aesthetic.
/// App shell pages (Overview, Connections, Island, Settings) and branded sheets use these tokens
/// so surfaces stay consistent: near-black canvas, charcoal cards, light ink, white pill CTAs.
enum BrimChrome {
    static let canvas = Color(nsColor: NSColor(calibratedWhite: 0.07, alpha: 1))
    static let sidebar = Color(nsColor: NSColor(calibratedWhite: 0.09, alpha: 1))
    static let card = Color(nsColor: NSColor(calibratedWhite: 0.13, alpha: 1))
    static let selected = Color.white.opacity(0.08)
    static let ink = Color.white.opacity(0.92)
    static let muted = Color.white.opacity(0.45)
    static let hairline = Color.white.opacity(0.10)
    static let ctaFill = Color.white
    static let ctaLabel = Color.black

    static let windowBackground = NSColor(calibratedWhite: 0.07, alpha: 1)

    static let section = Font.system(size: 12, weight: .semibold, design: .rounded)
    static let headline = Font.system(size: 15, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 13, weight: .medium, design: .rounded)
    static let caption = Font.system(size: 11, weight: .medium, design: .rounded)

    static func primaryButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(enabled ? ctaLabel : ink.opacity(0.35))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(enabled ? ctaFill : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

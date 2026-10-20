import AppKit
import IslandCore

/// Images shipped with the app. `scripts/build-app.sh` copies SwiftPM's resource bundle into
/// `Contents/Resources`; `swift run` leaves it next to the executable. Looked up by hand instead of
/// through `Bundle.module`, which crashes when the bundle is missing.
enum BrimAssets {
    private static let bundleName = "Brim_BrimApp.bundle"

    private static let root: URL? = {
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()]
        return candidates.compactMap { $0?.appendingPathComponent(bundleName) }
            .lazy.compactMap { Bundle(url: $0)?.resourceURL }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }()

    private static var cache: [String: NSImage] = [:]

    /// A black-on-transparent image marked as a template, so it can be tinted.
    static func template(_ path: String) -> NSImage? {
        if let image = cache[path] { return image }
        guard let url = root?.appendingPathComponent(path), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache[path] = image
        return image
    }

    static func logo(for kind: ToolKind) -> NSImage? {
        kind.logoName.flatMap { template("Logos/\($0).png") }
    }

    /// The tool's logo sized for a menu or the menu bar, or its SF Symbol when there's no logo.
    static func menuImage(for kind: ToolKind, size: CGFloat = 16) -> NSImage? {
        guard let logo = logo(for: kind)?.copy() as? NSImage else {
            return NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.displayName)
        }
        logo.size = NSSize(width: size, height: size)
        logo.isTemplate = true
        return logo
    }

    /// Brim mark for the menu bar status item (logo 1a island template).
    static var brimMenuMark: NSImage? {
        guard let image = template("Logos/brim-menu.png")?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 16, height: 14)
        image.isTemplate = true
        return image
    }

    /// Status-item glyph: always the Brim mark. When `attention` is true, a small corner
    /// badge overlays the template (same tint as the mark — no color animation).
    static func statusItemImage(attention: Bool) -> NSImage? {
        guard let mark = brimMenuMark else { return nil }
        guard attention else { return mark }

        let markSize = NSSize(width: 16, height: 14)
        let canvas = NSSize(width: 18, height: 16)
        let image = NSImage(size: canvas, flipped: false) { bounds in
            mark.draw(
                in: NSRect(x: 0, y: 1, width: markSize.width, height: markSize.height),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            // Top-trailing attention dot (template black → system menu-bar tint).
            let diameter: CGFloat = 5
            let badge = NSRect(
                x: bounds.width - diameter,
                y: bounds.height - diameter - 0.5,
                width: diameter,
                height: diameter
            )
            NSColor.black.setFill()
            NSBezierPath(ovalIn: badge).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

extension ToolKind {
    /// File name of the tool's own logo in `Resources/Logos`; custom connections have none.
    var logoName: String? {
        switch self {
        case .claude, .codex, .cursor, .windsurf, .copilot, .openrouter: return rawValue
        case .customLogs, .customEndpoint: return nil
        }
    }
}

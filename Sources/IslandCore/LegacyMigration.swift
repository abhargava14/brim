import Foundation

/// Brim used to be called AI Island. This moves what the old name left on disk, once.
public enum LegacyMigration {
    public static let supportFolder = "Brim"
    public static let legacySupportFolder = "AIIsland"
    /// Names the old status line bridge script, and so marks Claude Code commands that ran it.
    public static let legacyMarker = "ai-island-statusline"

    public static var applicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// Moves everything from the old support folder into the new one without overwriting
    /// anything already there, then removes the old folder if it's empty.
    /// Returns true when something moved.
    @discardableResult
    public static func moveSupportFolder(in base: URL = applicationSupport) -> Bool {
        let fm = FileManager.default
        let old = base.appendingPathComponent(legacySupportFolder, isDirectory: true)
        let new = base.appendingPathComponent(supportFolder, isDirectory: true)
        guard let items = try? fm.contentsOfDirectory(atPath: old.path) else { return false }

        if !fm.fileExists(atPath: new.path), (try? fm.moveItem(at: old, to: new)) != nil { return true }

        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        var moved = false
        for item in items where !fm.fileExists(atPath: new.appendingPathComponent(item).path) {
            if (try? fm.moveItem(at: old.appendingPathComponent(item), to: new.appendingPathComponent(item))) != nil { moved = true }
        }
        if (try? fm.contentsOfDirectory(atPath: old.path))?.isEmpty == true { try? fm.removeItem(at: old) }
        return moved
    }
}

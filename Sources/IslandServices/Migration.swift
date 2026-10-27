import Foundation
import IslandCore

public enum BrimMigration {
    /// Carries files, Keychain tokens, and the Claude Code status line over from AI Island.
    /// Safe to run on every launch; it does nothing once there's nothing left to move.
    ///
    /// After Check for Updates, `PostUpdateLive` arms so the first account refresh may unlock
    /// Keychain for **live plan %** (pick **Always Allow**). Background polls stay Fail-UI.
    public static func run() {
        LegacyMigration.moveSupportFolder()
        // Never migrate / touch Keychain during screenshot or agent QA (no password sheets).
        if !BrimQA.skipCredentials {
            let interactive = PostUpdateLive.isArmed
            let accounts = ConnectionStore().load().connections.map(\.id)
            Keychain.migrateLegacy(accounts: accounts, allowPrompt: interactive)
        }
        _ = try? ClaudeStatusLineSetup(
            supportDirectory: ClaudeStatusLineSetup.defaultSupportDirectory,
            settingsURL: ClaudeStatusLineSetup.defaultSettingsURL()
        ).repairIfMoved()
    }
}

/// One-shot flag the in-app updater leaves before `open`. First Refresh after relaunch may
/// prompt Keychain once for live Claude/Cursor plan % — not a soft-fail skip.
public enum PostUpdateLive {
    static var flagURL: URL {
        ClaudeStatusLineSetup.defaultSupportDirectory.appendingPathComponent("post-update-live")
    }

    /// True while the flag file exists (before `consume`).
    public static var isArmed: Bool {
        FileManager.default.fileExists(atPath: flagURL.path)
    }

    public static func arm() {
        let dir = flagURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: flagURL.path, contents: Data(), attributes: nil)
        // Drop the old quiet flag from 0.5.3 if present.
        let legacy = ClaudeStatusLineSetup.defaultSupportDirectory.appendingPathComponent("post-update-quiet")
        try? FileManager.default.removeItem(at: legacy)
    }

    /// Returns true once if the updater armed a live relaunch, then clears the flag.
    @discardableResult
    public static func consume() -> Bool {
        let url = flagURL
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.removeItem(at: url)
        return true
    }
}

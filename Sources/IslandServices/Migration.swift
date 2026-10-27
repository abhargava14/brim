import Foundation
import IslandCore

public enum BrimMigration {
    /// Carries files, Keychain tokens, and the Claude Code status line over from AI Island.
    /// Safe to run on every launch; it does nothing once there's nothing left to move.
    ///
    /// Keychain migrate always uses Fail-UI (`KeychainSilence`) and soft-fails — Check for
    /// Updates / post-replace relaunch must never force a Mac login-password unlock.
    public static func run() {
        LegacyMigration.moveSupportFolder()
        // Never migrate / touch Keychain during screenshot or agent QA (no password sheets).
        // Post-update quiet flag: skip credential migrate once after Check for Updates relaunch.
        if !BrimQA.skipCredentials, !PostUpdateQuiet.consume() {
            let accounts = ConnectionStore().load().connections.map(\.id)
            Keychain.migrateLegacy(accounts: accounts)
        }
        _ = try? ClaudeStatusLineSetup(
            supportDirectory: ClaudeStatusLineSetup.defaultSupportDirectory,
            settingsURL: ClaudeStatusLineSetup.defaultSettingsURL()
        ).repairIfMoved()
    }
}

/// One-shot flag the in-app updater leaves before `open` so relaunch skips Keychain migrate.
/// Usage logs and cached plan windows still load; credentials soft-fail until the next quiet launch.
enum PostUpdateQuiet {
    static var flagURL: URL {
        ClaudeStatusLineSetup.defaultSupportDirectory.appendingPathComponent("post-update-quiet")
    }

    static func arm() {
        let dir = flagURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: flagURL.path, contents: Data(), attributes: nil)
    }

    /// Returns true once if the updater armed a quiet relaunch, then clears the flag.
    @discardableResult
    static func consume() -> Bool {
        let url = flagURL
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.removeItem(at: url)
        return true
    }
}

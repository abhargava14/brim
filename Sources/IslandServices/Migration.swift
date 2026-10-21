import Foundation
import IslandCore

public enum BrimMigration {
    /// Carries files, Keychain tokens, and the Claude Code status line over from AI Island.
    /// Safe to run on every launch; it does nothing once there's nothing left to move.
    public static func run() {
        LegacyMigration.moveSupportFolder()
        // Never migrate / touch Keychain during screenshot or agent QA (no password sheets).
        if !BrimQA.skipCredentials {
            let accounts = ConnectionStore().load().connections.map(\.id)
            Keychain.migrateLegacy(accounts: accounts)
        }
        _ = try? ClaudeStatusLineSetup(
            supportDirectory: ClaudeStatusLineSetup.defaultSupportDirectory,
            settingsURL: ClaudeStatusLineSetup.defaultSettingsURL()
        ).repairIfMoved()
    }
}

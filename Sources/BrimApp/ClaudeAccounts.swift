import AppKit
import Foundation
import IslandCore
import IslandServices

/// Hook that lets the Add Account window call `ClaudeAccountSetup` without IslandCore knowing
/// about AppKit. Wired once at launch; until then, Add Account falls back to choosing a log folder.
@MainActor
enum ClaudeAccountHook {
    static var addAccount: ((_ label: String) async throws -> ClaudeAccount)?

    static var canSignIn: Bool { addAccount != nil }

    /// Points the hook at `ClaudeAccountSetup` so a second Claude account can be signed in from the app.
    static func install() {
        addAccount = { label in
            try await ClaudeAccountSetup.addAccount(label: label) { url in
                Task { @MainActor in NSWorkspace.shared.open(url) }
            }
        }
    }
}

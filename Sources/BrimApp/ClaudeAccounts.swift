import AppKit
import Foundation
import IslandCore
import IslandServices

/// Hook that lets Add Connection call `ClaudeAccountSetup` without IslandCore knowing about AppKit.
/// Wired once at launch. Sign-in is the primary Claude path; log folders stay optional / advanced.
@MainActor
enum ClaudeAccountHook {
    static var addAccount: ((_ label: String) async throws -> ClaudeAccount)?

    static var canSignIn: Bool { addAccount != nil }

    /// Points the hook at Anthropic browser OAuth via `ClaudeAccountSetup`.
    static func install() {
        addAccount = { label in
            try await ClaudeAccountSetup.addAccount(label: label) { url in
                Task { @MainActor in NSWorkspace.shared.open(url) }
            }
        }
    }
}

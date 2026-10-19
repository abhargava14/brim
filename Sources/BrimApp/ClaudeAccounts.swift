import Foundation
import IslandCore

/// Where adding a second Claude account plugs in. `ClaudeAccountSetup.addAccount(label:)` (being
/// built on the `claude-usage` branch) signs in a separate Claude Code profile and returns the
/// connection that tracks it; wire it once at launch:
///
///     ClaudeAccounts.addAccount = { label in try await ClaudeAccountSetup.addAccount(label: label) }
///
/// Until it is set, the Add Account window offers choosing that profile's log folder instead.
@MainActor
enum ClaudeAccounts {
    static var addAccount: ((_ label: String) async throws -> Connection)?

    static var canSignIn: Bool { addAccount != nil }
}

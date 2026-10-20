import Foundation

/// Same-auth-email policy for Claude connections: normalize, detect, refuse, and collapse.
/// Shared by the app and `brim` CLI so both report the same user-visible message.
public enum ClaudeDuplicateEmail {
    /// Exact copy shown in the Add Account UI, launch alert, and CLI stderr.
    public static func userMessage(email: String) -> String {
        "A Claude account for \(AccountEmail.normalize(email)) is already connected."
    }

    /// Stored option first; otherwise the live email from the Claude Code config folder (when readable).
    public static func resolvedEmail(
        for connection: Connection,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        liveEmail: ((URL) -> String?)? = nil
    ) -> String? {
        if let stored = connection.accountEmail { return stored }
        guard connection.kind == .claude,
              let dir = connection.claudeConfigDir(home: home)
        else { return nil }
        let raw = liveEmail?(dir) ?? ClaudeAccounts.account(configDir: dir, home: home).email
        guard let raw, !raw.isEmpty else { return nil }
        return AccountEmail.normalize(raw)
    }

    /// Another Claude connection that already owns this auth email (normalized), optionally excluding one id.
    public static func existing(
        email: String?,
        in connections: [Connection],
        excluding id: String? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        liveEmail: ((URL) -> String?)? = nil
    ) -> Connection? {
        guard let email, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let needle = AccountEmail.normalize(email)
        return connections.first { connection in
            if let id, connection.id == id { return false }
            guard connection.kind == .claude else { return false }
            return resolvedEmail(for: connection, home: home, liveEmail: liveEmail) == needle
        }
    }

    /// True when adding/linking `candidateConfigDir` for `email` would collide with `existing`.
    /// Same folder is a reconnect, not a duplicate (“Claude Code” vs “Claude · Personal” with one email still collide).
    public static func isDuplicate(
        email: String?,
        candidateConfigDir: URL?,
        against existing: Connection,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        liveEmail: ((URL) -> String?)? = nil
    ) -> Bool {
        guard let email, !email.isEmpty, existing.kind == .claude else { return false }
        let existingEmail = resolvedEmail(for: existing, home: home, liveEmail: liveEmail)
        guard AccountEmail.matches(email, existingEmail) else { return false }
        let existingDir = existing.claudeConfigDir(home: home)?.standardizedFileURL
        let candidate = candidateConfigDir?.standardizedFileURL
        if let existingDir, let candidate, existingDir == candidate { return false }
        return true
    }

    public struct DedupeResult: Equatable, Sendable {
        /// Connections after collapsing each email group to one keeper.
        public var connections: [Connection]
        /// Normalized emails that had more than one connection (user should be told).
        public var collapsedEmails: [String]
        /// How many connection rows were removed.
        public var removedCount: Int

        public init(connections: [Connection], collapsedEmails: [String], removedCount: Int) {
            self.connections = connections
            self.collapsedEmails = collapsedEmails
            self.removedCount = removedCount
        }
    }

    /// Collapse same-email Claude connections to one (prefer enabled, then stored email, then stable id).
    /// Keeper receives a stored `accountEmail` when missing. Callers must report `collapsedEmails` to the user.
    public static func dedupe(
        _ connections: [Connection],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        liveEmail: ((URL) -> String?)? = nil
    ) -> DedupeResult {
        var byEmail: [String: [Connection]] = [:]
        for connection in connections where connection.kind == .claude {
            guard let email = resolvedEmail(for: connection, home: home, liveEmail: liveEmail)
            else { continue }
            byEmail[email, default: []].append(connection)
        }

        var removeIDs = Set<String>()
        var collapsed: [String] = []
        var updated = connections

        for (email, group) in byEmail where group.count > 1 {
            collapsed.append(email)
            let keeper = group.max { a, b in
                if a.isEnabled != b.isEnabled { return !a.isEnabled && b.isEnabled }
                let aEmail = a.accountEmail != nil
                let bEmail = b.accountEmail != nil
                if aEmail != bEmail { return !aEmail && bEmail }
                return a.id > b.id
            }!
            for connection in group where connection.id != keeper.id {
                removeIDs.insert(connection.id)
            }
            if let index = updated.firstIndex(where: { $0.id == keeper.id }),
               updated[index].accountEmail == nil {
                updated[index].options[Connection.Option.accountEmail] = email
            }
        }

        guard !removeIDs.isEmpty else {
            return DedupeResult(connections: connections, collapsedEmails: [], removedCount: 0)
        }
        updated.removeAll { removeIDs.contains($0.id) }
        return DedupeResult(
            connections: updated,
            collapsedEmails: collapsed.sorted(),
            removedCount: removeIDs.count
        )
    }
}

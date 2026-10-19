import Foundation

/// A github.com account the GitHub CLI is signed in to.
public struct GitHubAccount: Equatable, Identifiable, Sendable {
    public var login: String
    public var isActive: Bool
    public var id: String { login }

    public init(login: String, isActive: Bool) {
        self.login = login
        self.isActive = isActive
    }

    /// Parses `gh auth status --hostname github.com --json hosts`, active account first. The output has no tokens.
    public static func parseStatus(_ data: Data) -> [GitHubAccount] {
        guard let root = JSON.object(data), let hosts = root["hosts"] as? [String: Any],
              let entries = hosts["github.com"] as? [[String: Any]]
        else { return [] }
        let accounts = entries.compactMap { entry -> GitHubAccount? in
            guard let login = entry["login"] as? String, !login.isEmpty,
                  (entry["state"] as? String ?? "success") == "success"
            else { return nil }
            return GitHubAccount(login: login, isActive: entry["active"] as? Bool ?? false)
        }
        return accounts.filter(\.isActive) + accounts.filter { !$0.isActive }
    }
}

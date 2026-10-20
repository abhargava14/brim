import Foundation

/// Normalized account emails for duplicate detection across connections.
public enum AccountEmail {
    public static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func matches(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        return normalize(a) == normalize(b)
    }
}

/// One Claude Code sign-in on this Mac: a config folder (`~/.claude`, or any `CLAUDE_CONFIG_DIR`
/// such as `~/.claude-personal`) with its own logs, `.claude.json` and Keychain item.
public struct ClaudeAccount: Equatable, Sendable {
    public let configDir: URL
    /// `~/.claude` used without `CLAUDE_CONFIG_DIR`, the folder plain `claude` signs in to.
    public let isDefault: Bool
    public let email: String?
    /// `oauthAccount.organizationType`, e.g. `claude_team`, `claude_max`.
    public let organizationType: String?
    /// `oauthAccount.userRateLimitTier`, e.g. `default_claude_max_5x`.
    public let rateLimitTier: String?

    public init(configDir: URL, isDefault: Bool, email: String?, organizationType: String?, rateLimitTier: String?) {
        self.configDir = configDir
        self.isDefault = isDefault
        self.email = email
        self.organizationType = organizationType
        self.rateLimitTier = rateLimitTier
    }

    public var isSignedIn: Bool { organizationType != nil || email != nil }

    public var projectsDir: URL { configDir.appendingPathComponent("projects") }

    /// "Work" for Team and Enterprise organizations, "Personal" for everything else.
    public var kindLabel: String {
        let type = organizationType?.lowercased() ?? ""
        return type.contains("team") || type.contains("enterprise") ? "Work" : "Personal"
    }

    /// The connection name Brim suggests, e.g. "Claude · Work".
    public var suggestedName: String { "Claude · \(kindLabel)" }

    /// The plan as Claude reports it ("Team", "Max 5×"), only as a label; limits come from the service.
    public var planLabel: String? {
        let type = organizationType?.lowercased() ?? ""
        if type.contains("enterprise") { return "Enterprise" }
        if type.contains("team") { return "Team" }
        let tier = rateLimitTier?.lowercased() ?? ""
        if tier.contains("max_20x") { return "Max 20×" }
        if tier.contains("max_5x") || type.contains("max") { return "Max 5×" }
        if type.contains("pro") { return "Pro" }
        return nil
    }

    /// Stable key for caches; derived from the folder, never from the email.
    public var key: String { String(SHA256.hex(ClaudeAccounts.standardPath(configDir)).prefix(16)) }

    /// Keychain service names Claude Code may have used for this folder, most likely first.
    /// Claude Code names the item `Claude Code-credentials`, plus `-<first 8 hex of sha256(path)>`
    /// whenever `CLAUDE_CONFIG_DIR` is set.
    public var keychainServices: [String] {
        let base = "Claude Code-credentials"
        let path = ClaudeAccounts.standardPath(configDir).precomposedStringWithCanonicalMapping
        let hashed = [path, path + "/"].map { base + "-" + String(SHA256.hex($0).prefix(8)) }
        return isDefault ? [base] + hashed : hashed
    }
}

/// Finds Claude Code config folders and reads who is signed in to each (metadata only).
public enum ClaudeAccounts {
    /// Every folder that looks like a Claude Code config folder: `~/.claude`, the folders in
    /// `CLAUDE_CONFIG_DIR`, `~/.claude-*`, `~/.config/claude*`, and any `extra` ones.
    public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                environment: [String: String] = ProcessInfo.processInfo.environment,
                                extra: [URL] = []) -> [ClaudeAccount] {
        let fm = FileManager.default
        var candidates = [home.appendingPathComponent(".claude")]
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            candidates += custom.split(separator: ",").map { expand(String($0), home: home) }
        }
        for (parent, prefix) in [(home, ".claude-"), (home.appendingPathComponent(".config"), "claude")] {
            let names = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
            candidates += names.filter { $0.hasPrefix(prefix) && !$0.hasSuffix(".json") && !$0.hasSuffix(".backup") }
                .sorted()
                .map { parent.appendingPathComponent($0) }
        }
        candidates += extra

        var seen = Set<String>()
        var accounts: [ClaudeAccount] = []
        for dir in candidates {
            let path = standardPath(dir)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue, seen.insert(path).inserted else { continue }
            let looksLikeClaude = fm.fileExists(atPath: dir.appendingPathComponent(".claude.json").path)
                || fm.fileExists(atPath: dir.appendingPathComponent("projects").path)
                || path == standardPath(home.appendingPathComponent(".claude"))
            guard looksLikeClaude else { continue }
            accounts.append(account(configDir: dir, home: home))
        }
        return accounts
    }

    /// Reads one folder's sign-in. The default folder keeps its config in `~/.claude.json`.
    public static func account(configDir: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ClaudeAccount {
        let isDefault = standardPath(configDir) == standardPath(home.appendingPathComponent(".claude"))
        var files = [configDir.appendingPathComponent(".claude.json")]
        if isDefault { files.insert(home.appendingPathComponent(".claude.json"), at: 0) }
        let oauth = files.lazy.compactMap { url -> [String: Any]? in
            guard let data = try? Data(contentsOf: url), let root = JSON.object(data) else { return nil }
            return root["oauthAccount"] as? [String: Any]
        }.first
        return ClaudeAccount(
            configDir: configDir,
            isDefault: isDefault,
            email: JSON.string(oauth, "emailAddress"),
            organizationType: JSON.string(oauth, "organizationType"),
            rateLimitTier: JSON.string(oauth, "userRateLimitTier")
        )
    }

    /// A new folder for another account: `~/.claude-<label>`, never one that already exists.
    public static func newConfigDir(label: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let slug = label.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { text, char in if !(char == "-" && text.hasSuffix("-")) { text.append(char) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = ".claude-" + (slug.isEmpty ? "account" : slug)
        var candidate = home.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = home.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        return candidate
    }

    static func expand(_ path: String, home: URL) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") { return home.appendingPathComponent(String(trimmed.dropFirst(2))) }
        return URL(fileURLWithPath: trimmed)
    }

    static func standardPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// The part of Claude Code's Keychain item Brim uses. Never printed: `description` is redacted.
public struct ClaudeCredentials: Equatable, Sendable, CustomStringConvertible {
    public let accessToken: String
    /// Present when Claude Code stored an OAuth refresh token; used to renew the access token.
    public let refreshToken: String?
    public let expiresAt: Date?
    public let subscriptionType: String?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date?, subscriptionType: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
    }

    /// Parses the item's JSON (`claudeAiOauth.accessToken`, `expiresAt` in Unix milliseconds).
    public static func parse(_ data: Data) -> ClaudeCredentials? {
        guard let root = JSON.object(data), let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = JSON.string(oauth, "accessToken")
        else { return nil }
        let expires = JSON.double(oauth, "expiresAt").map { Date(timeIntervalSince1970: $0 > 100_000_000_000 ? $0 / 1000 : $0) }
        return ClaudeCredentials(
            accessToken: token,
            refreshToken: JSON.string(oauth, "refreshToken"),
            expiresAt: expires,
            subscriptionType: JSON.string(oauth, "subscriptionType")
        )
    }

    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(60)
    }

    public var description: String { "ClaudeCredentials(<redacted>)" }
}

/// Fresh tokens from Claude Code's OAuth refresh (`POST …/v1/oauth/token`).
public struct ClaudeOAuthTokens: Equatable, Sendable, CustomStringConvertible {
    public let accessToken: String
    public let refreshToken: String?
    /// Seconds until the access token expires (typically 28800 = 8h).
    public let expiresIn: TimeInterval

    public init(accessToken: String, refreshToken: String?, expiresIn: TimeInterval) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
    }

    /// Parses Anthropic's token response. Fixtures must use redacted placeholders, never real tokens.
    public static func parse(_ data: Data) -> ClaudeOAuthTokens? {
        guard let root = JSON.object(data),
              let access = JSON.string(root, "access_token"),
              let expires = JSON.double(root, "expires_in"), expires > 0
        else { return nil }
        return ClaudeOAuthTokens(
            accessToken: access,
            refreshToken: JSON.string(root, "refresh_token"),
            expiresIn: expires
        )
    }

    public var description: String { "ClaudeOAuthTokens(<redacted>, expiresIn: \(Int(expiresIn))s)" }
}

/// Updates Claude Code's Keychain JSON in place after a refresh, preserving `mcpOAuth` and other fields.
public enum ClaudeCredentialsJSON {
    /// Writes the new access (and rotated refresh) token into `keychainJSON`. `expiresAt` is stored
    /// as Unix milliseconds, matching Claude Code.
    public static func applying(_ tokens: ClaudeOAuthTokens, to keychainJSON: Data, now: Date = Date()) -> Data? {
        guard var root = JSON.object(keychainJSON),
              var oauth = root["claudeAiOauth"] as? [String: Any]
        else { return nil }
        oauth["accessToken"] = tokens.accessToken
        if let refresh = tokens.refreshToken { oauth["refreshToken"] = refresh }
        oauth["expiresAt"] = (now.timeIntervalSince1970 + tokens.expiresIn) * 1000
        root["claudeAiOauth"] = oauth
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        else { return nil }
        return data
    }
}

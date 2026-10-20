import Foundation

/// One thing the user connected. There is no limit on how many a user can add.
///
/// Secrets (tokens, API keys) are never stored here; the app keeps them in the Keychain under the
/// connection's `id`.
public struct Connection: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: ToolKind
    /// The user's label, e.g. "Claude · Work".
    public var name: String
    /// A plan ID from `Plans.options(for:)`, or `Plans.automatic`.
    public var planID: String
    /// Connected (true) or disconnected but kept (false).
    public var isEnabled: Bool
    /// Kind-specific settings; see `Option`.
    public var options: [String: String]

    public enum Option {
        /// Log folder override (log-based kinds).
        public static let path = "path"
        /// A Claude Code config folder (`CLAUDE_CONFIG_DIR`), e.g. `~/.claude-personal` (Claude).
        public static let configDir = "configDir"
        /// `claude` or `codex` (custom log folders).
        public static let format = "format"
        /// Endpoint URL (custom endpoints).
        public static let url = "url"
        /// Header that carries the token, e.g. `Authorization` (custom endpoints).
        public static let authHeader = "authHeader"
        /// Prefix before the token in that header, e.g. `Bearer ` (custom endpoints).
        public static let authPrefix = "authPrefix"
        /// Dot paths into the JSON response (custom endpoints).
        public static let usedPath = "usedPath"
        public static let limitPath = "limitPath"
        public static let planPath = "planPath"
        public static let resetPath = "resetPath"
        /// Label for the quota bar, e.g. "Credits" (custom endpoints).
        public static let label = "label"
        /// Which of the GitHub CLI's accounts to read the token from; empty means the active one (Copilot).
        public static let githubLogin = "githubLogin"
        /// Auth email for the connection (Claude / account tools). Used to refuse duplicate adds.
        public static let accountEmail = "accountEmail"
    }

    /// Normalized auth email when known (stored option or empty).
    public var accountEmail: String? {
        let stored = option(Option.accountEmail)
        return stored.isEmpty ? nil : AccountEmail.normalize(stored)
    }

    public init(id: String = UUID().uuidString, kind: ToolKind, name: String? = nil, planID: String = Plans.automatic,
                isEnabled: Bool = true, options: [String: String] = [:]) {
        self.id = id
        self.kind = kind
        self.name = name ?? kind.displayName
        self.planID = planID
        self.isEnabled = isEnabled
        self.options = options.isEmpty ? Self.defaultOptions(for: kind) : options
    }

    public func option(_ key: String) -> String {
        options[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func defaultOptions(for kind: ToolKind) -> [String: String] {
        switch kind {
        case .customLogs:
            return [Option.format: LogFormat.claude.rawValue]
        case .customEndpoint:
            return [Option.authHeader: "Authorization", Option.authPrefix: "Bearer ", Option.label: "Usage"]
        default:
            return [:]
        }
    }

    /// The connections a fresh install starts with.
    public static let starterSet: [Connection] = [
        Connection(kind: .claude),
        Connection(kind: .codex),
    ]

    // MARK: - Logs

    public var logFormat: LogFormat? {
        switch kind {
        case .claude: return .claude
        case .codex: return .codex
        case .customLogs: return LogFormat(rawValue: option(Option.format)) ?? .claude
        default: return nil
        }
    }

    /// The folders to scan, or nil for account-based connections.
    public func logSource(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> LogSource? {
        guard let format = logFormat else { return nil }
        let custom = option(Option.path)
        if !custom.isEmpty {
            // Custom roots must resolve under $HOME and must not symlink-escape (see LogPath).
            guard let root = LogPath.sanitizeRoot(custom, home: home) else {
                return LogSource(format: format, roots: [])
            }
            return LogSource(format: format, roots: [root])
        }
        if kind == .customLogs { return LogSource(format: format, roots: []) }
        let configDir = option(Option.configDir)
        if kind == .claude, !configDir.isEmpty {
            return LogSource(format: format, roots: [ClaudeAccounts.expand(configDir, home: home).appendingPathComponent("projects")])
        }
        return LogSource(format: format, roots: DefaultLogLocations.roots(for: format, home: home, environment: environment))
    }

    /// The Claude Code config folder whose sign-in this connection shows: the `configDir` option,
    /// the folder holding the `projects` folder a custom path is in, or `~/.claude`.
    public func claudeConfigDir(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard kind == .claude else { return nil }
        let configDir = option(Option.configDir)
        if !configDir.isEmpty { return ClaudeAccounts.expand(configDir, home: home) }
        let custom = option(Option.path)
        guard !custom.isEmpty else { return home.appendingPathComponent(".claude") }
        var url = ClaudeAccounts.expand(custom, home: home).standardizedFileURL
        while url.pathComponents.count > 1 {
            if url.lastPathComponent == "projects" { return url.deletingLastPathComponent() }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    /// Whether this connection reads the tool's default folder (and so Claude Code's own status line applies).
    public var usesDefaultLocation: Bool {
        option(Option.path).isEmpty && option(Option.configDir).isEmpty && kind != .customLogs
    }
}

public struct LogSource: Equatable, Sendable {
    public var format: LogFormat
    public var roots: [URL]

    public init(format: LogFormat, roots: [URL]) {
        self.format = format
        self.roots = roots
    }

    /// Connections whose logs another connection of the same format already reads: every root
    /// is the same folder as, or inside, one of the other's roots. Their tokens would be counted
    /// twice in a combined total. Of two identical sources, the later one is the duplicate.
    public static func coveredIDs(in sources: [(id: String, source: LogSource)]) -> Set<String> {
        func path(_ url: URL) -> String {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        let paths = sources.map { $0.source.roots.map(path) }
        var covered = Set<String>()
        for (i, entry) in sources.enumerated() where !paths[i].isEmpty {
            let isCovered = paths[i].allSatisfy { root in
                sources.indices.contains { j in
                    guard j != i, sources[j].source.format == entry.source.format else { return false }
                    return paths[j].contains { other in
                        root.hasPrefix(other == "/" ? "/" : other + "/") || (root == other && j < i)
                    }
                }
            }
            if isCovered { covered.insert(entry.id) }
        }
        return covered
    }
}

/// Where each tool keeps its logs by default.
public enum DefaultLogLocations {
    public static func roots(for format: LogFormat, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        switch format {
        case .claude:
            var dirs: [URL] = []
            if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
                dirs += custom.split(separator: ",").map { URL(fileURLWithPath: String($0)).appendingPathComponent("projects") }
            }
            dirs.append(home.appendingPathComponent(".claude/projects"))
            dirs.append(home.appendingPathComponent(".config/claude/projects"))
            return dirs
        case .codex:
            let base = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".codex")
            return [base.appendingPathComponent("sessions"), base.appendingPathComponent("archived_sessions")]
        }
    }
}

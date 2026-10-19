import Foundation

/// Where a tool's usage comes from.
public enum DataSource: Sendable {
    /// Log files the tool writes on this Mac (read locally, nothing leaves the machine).
    case localLogs
    /// The tool's own account service, called with the user's existing sign-in or a token.
    case account
}

/// The log formats Brim can read.
public enum LogFormat: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code format"
        case .codex: return "Codex format"
        }
    }
}

/// A kind of connection. Users can add any number of connections, including several of one kind
/// (for example a personal and a work Claude account).
public enum ToolKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case codex
    case cursor
    case windsurf
    case copilot
    case openrouter
    /// Any folder of Claude Code or Codex style logs (another config dir, a synced folder, ...).
    case customLogs
    /// Any JSON endpoint that reports used and limit values.
    case customEndpoint

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .windsurf: return "Windsurf"
        case .copilot: return "GitHub Copilot"
        case .openrouter: return "OpenRouter"
        case .customLogs: return "Log folder"
        case .customEndpoint: return "Usage URL"
        }
    }

    public var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .copilot: return "Copilot"
        case .customLogs: return "Logs"
        case .customEndpoint: return "Custom"
        default: return displayName
        }
    }

    /// One line for the "Add connection" menu.
    public var blurb: String {
        switch self {
        case .claude: return "Reads Claude Code's local logs"
        case .codex: return "Reads Codex CLI's local logs"
        case .cursor: return "Uses your Cursor sign-in"
        case .windsurf: return "Uses your Windsurf sign-in"
        case .copilot: return "Uses the GitHub CLI or a token"
        case .openrouter: return "Uses an OpenRouter API key"
        case .customLogs: return "Any folder of Claude or Codex style logs"
        case .customEndpoint: return "Any JSON endpoint with used / limit values"
        }
    }

    public var source: DataSource {
        switch self {
        case .claude, .codex, .customLogs: return .localLogs
        case .cursor, .windsurf, .copilot, .openrouter, .customEndpoint: return .account
        }
    }

    /// Connectors that rely on a private, undocumented API and may break when the service changes.
    public var isExperimental: Bool {
        self == .cursor || self == .windsurf || self == .copilot
    }
}

/// Token counts of one request or an aggregate of many.
///
/// `fresh` = input + output + cache writes (work done without a cache hit);
/// `total` = fresh + cache reads (every token the model handled).
public struct TokenCounts: Equatable, Sendable {
    public var input: Int64
    public var output: Int64
    public var cacheWrite: Int64
    public var cacheRead: Int64

    public init(input: Int64 = 0, output: Int64 = 0, cacheWrite: Int64 = 0, cacheRead: Int64 = 0) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    public static let zero = TokenCounts()

    public var fresh: Int64 { input + output + cacheWrite }
    public var total: Int64 { fresh + cacheRead }
    public var isZero: Bool { total == 0 }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            cacheRead: lhs.cacheRead + rhs.cacheRead
        )
    }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs = lhs + rhs
    }
}

/// Usage metadata of one model response. Never carries prompt, message or code content.
public struct UsageEvent: Equatable, Sendable {
    public let format: LogFormat
    /// Unique per response; used to drop the duplicates the tools write.
    public let key: String
    public let timestamp: Date
    public let model: String
    public let tokens: TokenCounts
    public let sessionID: String?
    public let project: String?

    public init(format: LogFormat, key: String, timestamp: Date, model: String, tokens: TokenCounts, sessionID: String?, project: String?) {
        self.format = format
        self.key = key
        self.timestamp = timestamp
        self.model = model
        self.tokens = tokens
        self.sessionID = sessionID
        self.project = project
    }
}

/// A plan, quota or rate-limit window as reported by the tool itself (never computed from tokens).
public struct PlanWindow: Equatable, Sendable {
    public let label: String
    /// 0 to 100.
    public let usedPercent: Double
    public let resetsAt: Date?
    /// Optional absolute numbers, e.g. "212 / 300".
    public let detail: String?

    public init(label: String, usedPercent: Double, resetsAt: Date?, detail: String? = nil) {
        self.label = label
        self.usedPercent = min(max(usedPercent.isFinite ? usedPercent : 0, 0), 100)
        self.resetsAt = resetsAt
        self.detail = detail
    }
}

/// One day of usage for the history graph.
public struct DailyPoint: Equatable, Sendable, Identifiable {
    public let date: Date
    public let tokens: TokenCounts

    public var id: Date { date }

    public init(date: Date, tokens: TokenCounts) {
        self.date = date
        self.tokens = tokens
    }
}

/// Everything the UI shows for one connection.
public struct ToolSnapshot: Equatable, Sendable, Identifiable {
    /// The connection's ID.
    public let id: String
    public var kind: ToolKind
    public var name: String
    /// Number of log files found (log-based connections only).
    public var logFileCount: Int
    public var today: TokenCounts
    public var todaySessions: Int
    public var todayRequests: Int
    public var topModel: String?
    public var last5Hours: TokenCounts
    public var week: TokenCounts
    public var month: TokenCounts
    /// Oldest first; the last element is today. Empty for account-based connections.
    public var daily: [DailyPoint]
    public var lastActivity: Date?
    public var planWindows: [PlanWindow]
    /// The plan to show, chosen by the user or reported by the service.
    public var planName: String?
    /// Whether there is anything to show: logs were found, or the account service answered.
    public var hasData: Bool
    /// A short problem description, e.g. "Sign in to Cursor again".
    public var statusMessage: String?
    /// When account data was last fetched.
    public var updatedAt: Date?
    /// Which account this is (email or login), for any connection type that can tell: account
    /// services fill it from their own response or local sign-in, log tools from their own config.
    /// Read fresh each time; never saved to the connections file.
    public var accountLabel: String?

    public init(id: String, kind: ToolKind, name: String) {
        self.id = id
        self.kind = kind
        self.name = name
        logFileCount = 0
        today = .zero
        todaySessions = 0
        todayRequests = 0
        last5Hours = .zero
        week = .zero
        month = .zero
        daily = []
        planWindows = []
        hasData = false
    }

    public var isFound: Bool { hasData }
    public var hasTokenData: Bool { kind.source == .localLogs }

    /// The fullest plan window, which is the one most worth warning about.
    public var tightestWindow: PlanWindow? {
        planWindows.max { $0.usedPercent < $1.usedPercent }
    }

    /// A snapshot for a connection whose usage comes from its account service.
    public static func account(id: String, kind: ToolKind, name: String, usage: AccountUsage?, statusMessage: String?) -> ToolSnapshot {
        var snapshot = ToolSnapshot(id: id, kind: kind, name: name)
        snapshot.planWindows = usage?.windows ?? []
        snapshot.planName = usage?.planName
        snapshot.hasData = usage != nil
        snapshot.statusMessage = statusMessage
        snapshot.updatedAt = usage?.fetchedAt
        snapshot.accountLabel = usage?.accountLabel
        return snapshot
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let tools: [ToolSnapshot]
    public let generatedAt: Date
    /// Connections whose logs another connection already reads (see `LogSource.coveredIDs`);
    /// they keep their own card but stay out of the combined total.
    public let coveredIDs: Set<String>

    public init(tools: [ToolSnapshot], generatedAt: Date, coveredIDs: Set<String> = []) {
        self.tools = tools
        self.generatedAt = generatedAt
        self.coveredIDs = coveredIDs
    }

    public static let empty = UsageSnapshot(tools: [], generatedAt: .distantPast)

    public subscript(id: String) -> ToolSnapshot? {
        tools.first { $0.id == id }
    }

    public var todayTokens: Int64 {
        tools.filter { !coveredIDs.contains($0.id) }.reduce(0) { $0 + $1.today.total }
    }
}

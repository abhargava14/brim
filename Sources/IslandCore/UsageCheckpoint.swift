import Foundation

/// On-disk scan cursors and day aggregates so CLI and app cold starts do not re-parse every log.
///
/// Stored under `Application Support/Brim/usage-checkpoint.json`. Never contains prompt or message bodies —
/// only tokens, session ids, model names, project basenames, and file offsets.
public struct UsageCheckpoint: Codable, Equatable, Sendable {
    public var version: Int
    public var savedAt: Date
    /// Widest history window reflected in `connections` when this file was written.
    public var historyDays: Int
    public var connections: [String: ConnectionCheckpoint]

    public init(version: Int = 1, savedAt: Date = Date(), historyDays: Int, connections: [String: ConnectionCheckpoint] = [:]) {
        self.version = version
        self.savedAt = savedAt
        self.historyDays = historyDays
        self.connections = connections
    }

    public static let currentVersion = 1

    public static func defaultURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("usage-checkpoint.json")
    }

    public static func load(from url: URL) -> UsageCheckpoint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let checkpoint = try? decoder.decode(UsageCheckpoint.self, from: data),
              checkpoint.version == currentVersion
        else { return nil }
        return checkpoint
    }

    public func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

public struct ConnectionCheckpoint: Codable, Equatable, Sendable {
    public var files: [String: FileCheckpoint]
    /// Day key (`yyyyMMdd`) → event keys already counted that day.
    public var seenKeysByDay: [String: [String]]
    public var days: [String: DayCheckpoint]
    public var lastActivity: Date?
    public var transcriptWrites: [String: Date]
    public var codexPrimary: PlanWindow?
    public var codexPrimaryAt: Date?
    public var codexSecondary: PlanWindow?
    public var codexSecondaryAt: Date?

    public init(
        files: [String: FileCheckpoint] = [:],
        seenKeysByDay: [String: [String]] = [:],
        days: [String: DayCheckpoint] = [:],
        lastActivity: Date? = nil,
        transcriptWrites: [String: Date] = [:],
        codexPrimary: PlanWindow? = nil,
        codexPrimaryAt: Date? = nil,
        codexSecondary: PlanWindow? = nil,
        codexSecondaryAt: Date? = nil
    ) {
        self.files = files
        self.seenKeysByDay = seenKeysByDay
        self.days = days
        self.lastActivity = lastActivity
        self.transcriptWrites = transcriptWrites
        self.codexPrimary = codexPrimary
        self.codexPrimaryAt = codexPrimaryAt
        self.codexSecondary = codexSecondary
        self.codexSecondaryAt = codexSecondaryAt
    }
}

public struct FileCheckpoint: Codable, Equatable, Sendable {
    public var offset: UInt64
    public var size: UInt64
    public var modified: Date
    public var format: LogFormat

    public init(offset: UInt64, size: UInt64, modified: Date, format: LogFormat) {
        self.offset = offset
        self.size = size
        self.modified = modified
        self.format = format
    }
}

public struct DayCheckpoint: Codable, Equatable, Sendable {
    public var tokens: TokenCounts
    public var requests: Int
    public var sessions: [String]
    public var modelTokens: [String: TokenCounts]
    /// Present only for "today" when saved; past days omit session detail to keep RSS down.
    public var sessionUsage: [String: SessionCheckpoint]?

    public init(
        tokens: TokenCounts = .zero,
        requests: Int = 0,
        sessions: [String] = [],
        modelTokens: [String: TokenCounts] = [:],
        sessionUsage: [String: SessionCheckpoint]? = nil
    ) {
        self.tokens = tokens
        self.requests = requests
        self.sessions = sessions
        self.modelTokens = modelTokens
        self.sessionUsage = sessionUsage
    }
}

public struct SessionCheckpoint: Codable, Equatable, Sendable {
    public var project: String?
    public var model: String?
    public var latest: Date
    public var tokens: TokenCounts
    public var requests: Int

    public init(project: String?, model: String?, latest: Date, tokens: TokenCounts, requests: Int) {
        self.project = project
        self.model = model
        self.latest = latest
        self.tokens = tokens
        self.requests = requests
    }
}

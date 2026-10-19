import Foundation

/// The connections file shared by the app and the `ai-island` command:
/// `~/Library/Application Support/AIIsland/connections.json`.
///
/// Tokens are never written here; they live in the Keychain, keyed by connection ID.
public struct ConnectionFile: Codable, Equatable, Sendable {
    public var version: Int
    public var connections: [Connection]

    public init(version: Int = 1, connections: [Connection]) {
        self.version = version
        self.connections = connections
    }
}

public struct ConnectionStore: Sendable {
    public let url: URL

    public init(url: URL = ConnectionStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIIsland/connections.json")
    }

    /// The saved file, or a starter file when there is none yet.
    public func load() -> ConnectionFile {
        guard let data = try? Data(contentsOf: url),
              let file = try? Self.decoder.decode(ConnectionFile.self, from: data)
        else { return ConnectionFile(connections: Connection.starterSet) }
        return file
    }

    public func save(_ file: ConnectionFile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(file).write(to: url, options: .atomic)
    }

    /// When the file last changed, to notice edits made by the other side (app or CLI).
    public func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension ConnectionFile {
    /// Finds a connection by exact ID, case-insensitive name, or a unique ID prefix.
    public func find(_ query: String) -> Connection? {
        if let exact = connections.first(where: { $0.id == query }) { return exact }
        if let named = connections.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) { return named }
        let prefixed = connections.filter { $0.id.lowercased().hasPrefix(query.lowercased()) }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    public var enabledCount: Int { connections.filter(\.isEnabled).count }

    /// Adds a connected connection of `kind`, numbering the name when one of that kind already exists.
    /// There is no limit on how many connections a user can add.
    public mutating func add(_ kind: ToolKind, name: String? = nil) -> Connection {
        let sameKind = connections.filter { $0.kind == kind }.count
        let defaultName = sameKind == 0 ? kind.displayName : "\(kind.displayName) \(sameKind + 1)"
        let connection = Connection(kind: kind, name: name ?? defaultName)
        connections.append(connection)
        return connection
    }
}

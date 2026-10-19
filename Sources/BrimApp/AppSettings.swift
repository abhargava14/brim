import Foundation
import IslandCore

enum CompactMetric: String, CaseIterable, Identifiable {
    case auto
    case tokens
    case plan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Automatic (by plan)"
        case .tokens: return "Tokens"
        case .plan: return "Plan usage (%)"
        }
    }
}

/// Where the island goes: around the notch, below the menu bar (when another notch app or
/// crowded status icons need that space), or nowhere (menu bar item only).
enum IslandPlacement: String, CaseIterable, Identifiable {
    case wrapNotch
    case belowMenuBar
    case menuBarOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wrapNotch: return "Around the notch"
        case .belowMenuBar: return "Below the menu bar"
        case .menuBarOnly: return "Menu bar only (no island)"
        }
    }
}

/// What the island does while no connection is on.
enum EmptyIsland: String, CaseIterable, Identifiable {
    case small
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "Small island"
        case .hidden: return "Hide until connected"
        }
    }
}

/// User preferences (UserDefaults) and the connections file shared with the `brim` command.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard
    let store = ConnectionStore()
    private var lastSeenFileDate: Date?

    /// Every connection the user added, in display order. Saved to the shared connections file.
    @Published var connections: [Connection] {
        didSet { save() }
    }

    @Published var showIsland: Bool {
        didSet { defaults.set(showIsland, forKey: "showIsland") }
    }

    @Published var placement: IslandPlacement {
        didSet { defaults.set(placement.rawValue, forKey: "placement") }
    }

    @Published var hideInFullScreen: Bool {
        didSet { defaults.set(hideInFullScreen, forKey: "hideInFullScreen") }
    }

    @Published var showInMenuBar: Bool {
        didSet { defaults.set(showInMenuBar, forKey: "showInMenuBar") }
    }

    @Published var compactMetric: CompactMetric {
        didSet { defaults.set(compactMetric.rawValue, forKey: "compactMetric") }
    }

    @Published var expandOnHover: Bool {
        didSet { defaults.set(expandOnHover, forKey: "expandOnHover") }
    }

    /// Confetti, bouncing glyphs and other flourishes.
    @Published var playful: Bool {
        didSet { defaults.set(playful, forKey: "playful") }
    }

    /// A connection to always feature in the compact island; empty means automatic.
    @Published var pinnedID: String {
        didSet { defaults.set(pinnedID, forKey: "pinnedID") }
    }

    @Published var refreshSeconds: Double {
        didSet { defaults.set(refreshSeconds, forKey: "refreshSeconds") }
    }

    @Published var emptyIsland: EmptyIsland {
        didSet { defaults.set(emptyIsland.rawValue, forKey: "emptyIsland") }
    }

    private static let keys = ["showIsland", "placement", "hideInFullScreen", "showInMenuBar", "compactMetric",
                               "expandOnHover", "playful", "pinnedID", "refreshSeconds", "didOnboard",
                               "emptyIsland"]

    init() {
        Self.copyLegacyDefaults(into: defaults)
        let file = store.load()
        connections = file.connections
        showIsland = defaults.object(forKey: "showIsland") as? Bool ?? true
        placement = defaults.string(forKey: "placement").flatMap(IslandPlacement.init(rawValue:)) ?? .wrapNotch
        hideInFullScreen = defaults.object(forKey: "hideInFullScreen") as? Bool ?? true
        showInMenuBar = defaults.object(forKey: "showInMenuBar") as? Bool ?? true
        compactMetric = defaults.string(forKey: "compactMetric").flatMap(CompactMetric.init(rawValue:)) ?? .auto
        expandOnHover = defaults.object(forKey: "expandOnHover") as? Bool ?? true
        playful = defaults.object(forKey: "playful") as? Bool ?? true
        pinnedID = defaults.string(forKey: "pinnedID") ?? ""
        let refresh = defaults.double(forKey: "refreshSeconds")
        refreshSeconds = refresh > 0 ? refresh : 10
        emptyIsland = defaults.string(forKey: "emptyIsland").flatMap(EmptyIsland.init(rawValue:)) ?? .small
        save()
    }

    /// Carries preferences over from AI Island (bundled and `swift run` builds) when Brim has none yet.
    private static func copyLegacyDefaults(into defaults: UserDefaults) {
        guard !keys.contains(where: { defaults.object(forKey: $0) != nil }) else { return }
        for suite in ["com.aiisland.app", "AIIsland"] {
            guard let legacy = UserDefaults(suiteName: suite)?.persistentDomain(forName: suite), !legacy.isEmpty else { continue }
            for key in keys { if let value = legacy[key] { defaults.set(value, forKey: key) } }
            return
        }
    }

    private func save() {
        try? store.save(ConnectionFile(connections: connections))
        lastSeenFileDate = store.modificationDate()
    }

    /// Picks up changes the `brim` command made to the connections file.
    func reloadIfChangedOnDisk() {
        guard let date = store.modificationDate(), date != lastSeenFileDate else { return }
        lastSeenFileDate = date
        let file = store.load()
        if file.connections != connections { connections = file.connections }
    }

    var enabledConnections: [Connection] { connections.filter(\.isEnabled) }

    // MARK: - Connections

    func connection(_ id: String) -> Connection? {
        connections.first { $0.id == id }
    }

    /// Adds a connected connection of `kind`. Users can add as many as they like.
    @discardableResult
    func add(_ kind: ToolKind) -> Connection {
        var file = ConnectionFile(connections: connections)
        let connection = file.add(kind)
        connections = file.connections
        return connection
    }

    func update(_ connection: Connection) {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[index] = connection
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard var connection = connection(id), connection.isEnabled != enabled else { return }
        connection.isEnabled = enabled
        update(connection)
    }

    func remove(_ id: String) {
        connections.removeAll { $0.id == id }
        if pinnedID == id { pinnedID = "" }
    }

    func setAllEnabled(_ enabled: Bool) {
        connections = connections.map { var c = $0; c.isEnabled = enabled; return c }
    }

    func move(from source: IndexSet, to destination: Int) {
        connections.move(fromOffsets: source, toOffset: destination)
    }
}

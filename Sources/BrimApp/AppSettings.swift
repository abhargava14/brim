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

/// How a Claude card opens in the expanded island; a click on the card switches it.
enum ClaudeCardStyle: String, CaseIterable, Identifiable {
    case short
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .short: return "Short (5h, week, today)"
        case .full: return "Full (like Claude's /usage)"
        }
    }
}

/// When another app already draws in the notch.
enum NotchConflictPolicy: String, CaseIterable, Identifiable {
    case moveToMenuBar
    case stayOnNotch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .moveToMenuBar: return "Move to menu bar"
        case .stayOnNotch: return "Stay on the notch"
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
        didSet {
            defaults.set(placement.rawValue, forKey: "placement")
            // A manual change clears the auto-move hint; crowding may set the flag again.
            if isReady, !isApplyingCrowdingMove { placementMovedForCrowding = false }
        }
    }

    /// True when Brim itself switched to "Below the menu bar" because status icons left no room
    /// next to the notch. Shown as a hint in Settings.
    @Published var placementMovedForCrowding: Bool {
        didSet { defaults.set(placementMovedForCrowding, forKey: "placementMovedForCrowding") }
    }

    /// Suppresses clearing `placementMovedForCrowding` while an automatic move writes `placement`.
    var isApplyingCrowdingMove = false
    /// False during `init` so loading preferences doesn't wipe the crowding flag.
    private var isReady = false

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

    /// Off while screen sharing, to keep account emails off screen.
    @Published var showAccountEmails: Bool {
        didSet { defaults.set(showAccountEmails, forKey: "showAccountEmails") }
    }

    @Published var claudeCardStyle: ClaudeCardStyle {
        didSet { defaults.set(claudeCardStyle.rawValue, forKey: "claudeCardStyle") }
    }

    /// What to do when another app already draws in the notch.
    @Published var notchConflict: NotchConflictPolicy {
        didSet { defaults.set(notchConflict.rawValue, forKey: "notchConflict") }
    }

    /// User chose "Use Notch Anyway" after we stepped aside for another notch app.
    @Published var useNotchAnyway: Bool {
        didSet { defaults.set(useNotchAnyway, forKey: "useNotchAnyway") }
    }

    /// Show the one-time "Brim lives here" tip under the island after first run.
    @Published var pendingIslandTip: Bool {
        didSet { defaults.set(pendingIslandTip, forKey: "pendingIslandTip") }
    }

    private static let keys = ["showIsland", "placement", "hideInFullScreen", "showInMenuBar", "compactMetric",
                               "expandOnHover", "playful", "pinnedID", "refreshSeconds", "didOnboard",
                               "emptyIsland", "showAccountEmails", "placementMovedForCrowding", "claudeCardStyle",
                               "notchConflict", "useNotchAnyway", "pendingIslandTip"]

    init() {
        Self.copyLegacyDefaults(into: defaults)
        let file = store.load()
        connections = file.connections
        showIsland = defaults.object(forKey: "showIsland") as? Bool ?? true
        placement = defaults.string(forKey: "placement").flatMap(IslandPlacement.init(rawValue:)) ?? .wrapNotch
        placementMovedForCrowding = defaults.bool(forKey: "placementMovedForCrowding")
        hideInFullScreen = defaults.object(forKey: "hideInFullScreen") as? Bool ?? true
        // Off by default: menu bar stays Brim-icon-only; usage % lives in the island wings.
        showInMenuBar = defaults.object(forKey: "showInMenuBar") as? Bool ?? false
        compactMetric = defaults.string(forKey: "compactMetric").flatMap(CompactMetric.init(rawValue:)) ?? .auto
        expandOnHover = defaults.object(forKey: "expandOnHover") as? Bool ?? true
        // Quiet by default — less motion in the notch until the user opts in.
        playful = defaults.object(forKey: "playful") as? Bool ?? false
        pinnedID = defaults.string(forKey: "pinnedID") ?? ""
        let refresh = defaults.double(forKey: "refreshSeconds")
        refreshSeconds = refresh > 0 ? refresh : 10
        emptyIsland = defaults.string(forKey: "emptyIsland").flatMap(EmptyIsland.init(rawValue:)) ?? .small
        showAccountEmails = defaults.object(forKey: "showAccountEmails") as? Bool ?? true
        // Short Claude cards by default (minimal island).
        claudeCardStyle = defaults.string(forKey: "claudeCardStyle").flatMap(ClaudeCardStyle.init(rawValue:)) ?? .short
        notchConflict = defaults.string(forKey: "notchConflict").flatMap(NotchConflictPolicy.init(rawValue:)) ?? .moveToMenuBar
        useNotchAnyway = defaults.bool(forKey: "useNotchAnyway")
        pendingIslandTip = defaults.bool(forKey: "pendingIslandTip")
        isReady = true
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

    // MARK: - Duplicate emails

    /// Existing connection whose auth email matches (normalized), optionally excluding one id.
    func connection(withEmail email: String?, kind: ToolKind? = nil, excluding id: String? = nil) -> Connection? {
        guard let email, !email.isEmpty else { return nil }
        let needle = AccountEmail.normalize(email)
        return connections.first { connection in
            if let id, connection.id == id { return false }
            if let kind, connection.kind != kind { return false }
            if let stored = connection.accountEmail, stored == needle { return true }
            if connection.kind == .claude, let dir = connection.claudeConfigDir() {
                let live = ClaudeAccounts.account(configDir: dir).email
                return AccountEmail.matches(live, needle)
            }
            return false
        }
    }

    /// On launch: collapse same-email Claude connections to one (prefer enabled + stored email + token).
    /// Returns how many duplicates were removed.
    @discardableResult
    func dedupeClaudeConnectionsByEmail() -> Int {
        var byEmail: [String: [Connection]] = [:]
        for connection in connections where connection.kind == .claude {
            let email = connection.accountEmail
                ?? ClaudeAccounts.account(configDir: connection.claudeConfigDir() ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")).email.flatMap(AccountEmail.normalize)
            guard let email, !email.isEmpty else { continue }
            byEmail[email, default: []].append(connection)
        }
        var removeIDs = Set<String>()
        for (_, group) in byEmail where group.count > 1 {
            let keeper = group.max { a, b in
                // Prefer enabled, then one with a stored email option, then stable id.
                if a.isEnabled != b.isEnabled { return !a.isEnabled && b.isEnabled }
                let aEmail = a.accountEmail != nil
                let bEmail = b.accountEmail != nil
                if aEmail != bEmail { return !aEmail && bEmail }
                return a.id > b.id
            }!
            for connection in group where connection.id != keeper.id {
                removeIDs.insert(connection.id)
            }
            // Ensure keeper remembers the email.
            if var kept = connections.first(where: { $0.id == keeper.id }), kept.accountEmail == nil,
               let email = byEmail.first(where: { $0.value.contains(where: { $0.id == keeper.id }) })?.key {
                kept.options[Connection.Option.accountEmail] = email
                if let index = connections.firstIndex(where: { $0.id == kept.id }) {
                    connections[index] = kept
                }
            }
        }
        guard !removeIDs.isEmpty else { return 0 }
        connections.removeAll { removeIDs.contains($0.id) }
        if removeIDs.contains(pinnedID) { pinnedID = "" }
        return removeIDs.count
    }
}

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

/// Expanded island connection presentation (design v2 · 1a Cards / 1b Strip).
enum ExpandedLayout: String, CaseIterable, Identifiable {
    case cards
    case strip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cards: return "Cards"
        case .strip: return "Strip"
        }
    }

    var detail: String {
        switch self {
        case .cards: return "Full detail per connection; row scrolls past four."
        case .strip: return "One column each; seven fit without scrolling."
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

/// How the open island looks. The closed notch is always black.
enum IslandAppearance: String, CaseIterable, Identifiable {
    case dark
    case light
    case system

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Which screens get the island.
enum IslandDisplay: String, CaseIterable, Identifiable {
    /// The built-in display (with the notch), else the main one.
    case builtIn
    /// Follows the display you're working on.
    case all

    var id: String { rawValue }
    var title: String { self == .builtIn ? "Built-in" : "All displays" }
}

/// User preferences (UserDefaults) and the connections file shared with the `brim` command.
@MainActor
final class AppSettings: ObservableObject {
    /// Snapshot renders read and write a scratch suite and never touch the connections file.
    nonisolated static let isSnapshot = ProcessInfo.processInfo.environment["BRIM_SNAPSHOT_DIR"] != nil
    private let defaults = AppSettings.isSnapshot ? UserDefaults(suiteName: "com.brim.snapshot")! : UserDefaults.standard
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

    /// Legacy preference. Kept so older installs don't lose the key; the menu bar is always
    /// Brim-mark-only (usage lives in the island). Not shown in Settings or the status menu.
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

    /// Expanded island: Cards (wide) or Strip (narrow columns). Design v2 live prototype.
    @Published var expandedLayout: ExpandedLayout {
        didSet { defaults.set(expandedLayout.rawValue, forKey: "expandedLayout") }
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

    /// Tab order and which tabs show in the bar.
    @Published var tabLayout: TabLayout {
        didSet {
            defaults.set(tabLayout.order.map(\.rawValue), forKey: "tabOrder")
            defaults.set(tabLayout.hidden.map(\.rawValue).sorted(), forKey: "tabHidden")
        }
    }

    /// The tab the island opens on.
    @Published var selectedTab: TabID {
        didSet { defaults.set(selectedTab.rawValue, forKey: "selectedTab") }
    }

    @Published var appearance: IslandAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }

    @Published var display: IslandDisplay {
        didSet { defaults.set(display.rawValue, forKey: "display") }
    }

    /// ⌥Space opens the island from anywhere.
    @Published var hotkeyEnabled: Bool {
        didSet { defaults.set(hotkeyEnabled, forKey: "hotkeyEnabled") }
    }

    /// What the closed notch rotates through and what may interrupt it.
    @Published var closedMusic: Bool { didSet { defaults.set(closedMusic, forKey: "closedMusic") } }
    @Published var closedTimer: Bool { didSet { defaults.set(closedTimer, forKey: "closedTimer") } }
    @Published var closedAI: Bool { didSet { defaults.set(closedAI, forKey: "closedAI") } }
    @Published var interruptLimits: Bool { didSet { defaults.set(interruptLimits, forKey: "interruptLimits") } }
    @Published var interruptAccounts: Bool { didSet { defaults.set(interruptAccounts, forKey: "interruptAccounts") } }
    @Published var interruptTimerDone: Bool { didSet { defaults.set(interruptTimerDone, forKey: "interruptTimerDone") } }
    @Published var interruptEvents: Bool { didSet { defaults.set(interruptEvents, forKey: "interruptEvents") } }

    private static let keys = ["showIsland", "placement", "hideInFullScreen", "showInMenuBar", "compactMetric",
                               "expandOnHover", "playful", "pinnedID", "refreshSeconds", "didOnboard",
                               "emptyIsland", "showAccountEmails", "placementMovedForCrowding", "claudeCardStyle",
                               "expandedLayout", "notchConflict", "useNotchAnyway", "pendingIslandTip"]

    init() {
        Self.copyLegacyDefaults(into: defaults)
        let file = Self.isSnapshot ? ConnectionFile(connections: []) : store.load()
        connections = file.connections
        showIsland = defaults.object(forKey: "showIsland") as? Bool ?? true
        placement = defaults.string(forKey: "placement").flatMap(IslandPlacement.init(rawValue:)) ?? .wrapNotch
        placementMovedForCrowding = defaults.bool(forKey: "placementMovedForCrowding")
        hideInFullScreen = defaults.object(forKey: "hideInFullScreen") as? Bool ?? true
        // Legacy key only — menu bar is always icon-only regardless of this value.
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
        expandedLayout = defaults.string(forKey: "expandedLayout").flatMap(ExpandedLayout.init(rawValue:)) ?? .cards
        notchConflict = defaults.string(forKey: "notchConflict").flatMap(NotchConflictPolicy.init(rawValue:)) ?? .moveToMenuBar
        useNotchAnyway = defaults.bool(forKey: "useNotchAnyway")
        pendingIslandTip = defaults.bool(forKey: "pendingIslandTip")
        tabLayout = TabLayout(savedOrder: defaults.stringArray(forKey: "tabOrder") ?? [],
                              savedHidden: defaults.stringArray(forKey: "tabHidden") ?? [])
        selectedTab = defaults.string(forKey: "selectedTab").flatMap(TabID.init(rawValue:)) ?? .home
        appearance = defaults.string(forKey: "appearance").flatMap(IslandAppearance.init(rawValue:)) ?? .dark
        display = defaults.string(forKey: "display").flatMap(IslandDisplay.init(rawValue:)) ?? .builtIn
        hotkeyEnabled = defaults.object(forKey: "hotkeyEnabled") as? Bool ?? true
        closedMusic = defaults.object(forKey: "closedMusic") as? Bool ?? true
        closedTimer = defaults.object(forKey: "closedTimer") as? Bool ?? true
        closedAI = defaults.object(forKey: "closedAI") as? Bool ?? true
        interruptLimits = defaults.object(forKey: "interruptLimits") as? Bool ?? true
        interruptAccounts = defaults.object(forKey: "interruptAccounts") as? Bool ?? true
        interruptTimerDone = defaults.object(forKey: "interruptTimerDone") as? Bool ?? true
        interruptEvents = defaults.object(forKey: "interruptEvents") as? Bool ?? false
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
        guard !Self.isSnapshot else { return }
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

    /// Existing Claude connection whose auth email matches (normalized), optionally excluding one id.
    func connection(withEmail email: String?, kind: ToolKind? = nil, excluding id: String? = nil) -> Connection? {
        // Only Claude is gated by auth email today.
        if let kind, kind != .claude { return nil }
        return ClaudeDuplicateEmail.existing(email: email, in: connections, excluding: id)
    }

    /// On launch: collapse same-email Claude connections to one (prefer enabled + stored email).
    /// Callers must show `collapsedEmails` to the user — never silent.
    @discardableResult
    func dedupeClaudeConnectionsByEmail() -> ClaudeDuplicateEmail.DedupeResult {
        let result = ClaudeDuplicateEmail.dedupe(connections)
        guard result.removedCount > 0 else { return result }
        let removed = Set(connections.map(\.id)).subtracting(result.connections.map(\.id))
        connections = result.connections
        if removed.contains(pinnedID) { pinnedID = "" }
        return result
    }
}

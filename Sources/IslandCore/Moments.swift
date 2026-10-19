import Foundation

/// A moment worth showing on the island for a few seconds.
public struct IslandEvent: Identifiable, Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case connected, disconnected, warning, limit, milestone

        /// Lower shows first.
        public var priority: Int {
            switch self {
            case .limit: return 0
            case .warning: return 1
            case .milestone: return 2
            case .connected, .disconnected: return 3
            }
        }

        /// Urgent moments may cut a less important one short.
        public var isUrgent: Bool { self == .limit || self == .warning }
    }

    public let id: UUID
    public let connectionID: String
    public let kind: ToolKind
    public let style: Style
    public let title: String
    public let detail: String
    /// The connections a "connected" moment stands for (several when grouped).
    public let names: [String]
    public let createdAt: Date

    public init(id: UUID = UUID(), connectionID: String, kind: ToolKind, style: Style, title: String, detail: String,
                names: [String] = [], createdAt: Date = Date()) {
        self.id = id
        self.connectionID = connectionID
        self.kind = kind
        self.style = style
        self.title = title
        self.detail = detail
        self.names = names
        self.createdAt = createdAt
    }

    public static func connected(connectionID: String, kind: ToolKind, name: String, detail: String,
                                 createdAt: Date = Date()) -> IslandEvent {
        IslandEvent(connectionID: connectionID, kind: kind, style: .connected, title: "\(name) connected",
                    detail: detail, names: [name], createdAt: createdAt)
    }

    public var duration: TimeInterval {
        switch style {
        case .limit: return 8
        case .warning: return 7
        case .milestone, .connected: return 4.5
        case .disconnected: return 3
        }
    }

    public var celebrates: Bool { style == .connected || style == .milestone }

    /// One "connected" moment for several connections. Keeps this moment's identity.
    public func merged(with other: IslandEvent) -> IslandEvent {
        let all = names + other.names
        return IslandEvent(id: id, connectionID: connectionID, kind: kind, style: .connected,
                           title: "\(all.count) tools connected", detail: all.joined(separator: ", "),
                           names: all, createdAt: createdAt)
    }
}

/// Decides which moment the island shows and for how long. Pure state: the caller owns the timer,
/// asks `timeLeft(now:)` and calls `finishCurrent()` then `showNext(now:)` when it runs out.
///
/// - Moments wait in priority order (limit, warning, milestone, then connected / disconnected),
///   first come first served within a priority.
/// - A limit or warning cuts a less important moment short; that one goes back in the queue.
/// - "Connected" moments that arrive together become one.
/// - While paused (the island is expanded or hidden) the clock stops, so nothing expires unseen.
public struct MomentQueue: Sendable {
    public private(set) var current: IslandEvent?
    public private(set) var pending: [IslandEvent] = []
    public private(set) var isPaused = false
    /// Moments that waited longer than this are skipped when their turn comes.
    public var maxAge: TimeInterval = 300
    /// A resumed moment gets at least this long on screen.
    public static let minimumOnResume: TimeInterval = 1.5

    private var remaining: TimeInterval = 0
    private var runningSince: Date?
    /// Between two moments (a short gap so they read as separate); new moments wait for `showNext`.
    private var resting = false

    public init() {}

    /// Adds a moment. Returns true when `current` changed.
    @discardableResult
    public mutating func enqueue(_ event: IslandEvent, now: Date = Date()) -> Bool {
        if event.style == .connected {
            if let shown = current, shown.style == .connected {
                start(shown.merged(with: event), now: now)
                return true
            }
            if let index = pending.firstIndex(where: { $0.style == .connected }) {
                pending[index] = pending[index].merged(with: event)
                return false
            }
        }
        guard let shown = current else {
            if resting {
                insert(event)
                return false
            }
            start(event, now: now)
            return true
        }
        if event.style.isUrgent, event.style.priority < shown.style.priority {
            insert(shown, ahead: true)
            start(event, now: now)
            return true
        }
        insert(event)
        return false
    }

    /// Seconds until the current moment is done, or nil when nothing is running (or paused).
    public func timeLeft(now: Date = Date()) -> TimeInterval? {
        guard current != nil, !isPaused, let since = runningSince else { return nil }
        return max(0, remaining - now.timeIntervalSince(since))
    }

    public mutating func pause(now: Date = Date()) {
        guard !isPaused else { return }
        isPaused = true
        if let since = runningSince {
            remaining = max(0, remaining - now.timeIntervalSince(since))
            runningSince = nil
        }
    }

    public mutating func resume(now: Date = Date()) {
        guard isPaused else { return }
        isPaused = false
        if current != nil {
            remaining = max(remaining, Self.minimumOnResume)
            runningSince = now
        }
    }

    /// The current moment's time is up; the queue rests until `showNext`.
    public mutating func finishCurrent() {
        current = nil
        runningSince = nil
        resting = true
    }

    /// Shows the next waiting moment, skipping stale ones. Returns true when one started.
    @discardableResult
    public mutating func showNext(now: Date = Date()) -> Bool {
        resting = false
        pending.removeAll { now.timeIntervalSince($0.createdAt) > maxAge }
        guard !pending.isEmpty else { return false }
        start(pending.removeFirst(), now: now)
        return true
    }

    /// The user dismissed the current moment: move straight on to the next.
    @discardableResult
    public mutating func dismiss(now: Date = Date()) -> Bool {
        current = nil
        runningSince = nil
        return showNext(now: now)
    }

    private mutating func start(_ event: IslandEvent, now: Date) {
        current = event
        remaining = event.duration
        runningSince = isPaused ? nil : now
        resting = false
    }

    /// Keeps `pending` in priority order; `ahead` puts the moment first among its priority.
    private mutating func insert(_ event: IslandEvent, ahead: Bool = false) {
        let p = event.style.priority
        let index = pending.firstIndex { ahead ? $0.style.priority >= p : $0.style.priority > p } ?? pending.endIndex
        pending.insert(event, at: index)
    }
}

/// Remembers which plan-limit thresholds were announced, so a window hovering around one
/// doesn't alert again until it resets.
public struct LimitAlertMemory: Sendable {
    private struct Key: Hashable, Sendable {
        let connectionID: String
        let label: String
        let threshold: Double
    }

    private struct Entry: Sendable {
        let resetsAt: Date?
    }

    private var announced: [Key: Entry] = [:]
    /// Without a reset time, a window must fall this far below a threshold before it can alert again.
    public static let rearmMargin: Double = 20

    public init() {}

    /// Whether crossing `threshold` should be announced; remembers it when the answer is yes.
    public mutating func shouldAnnounce(connectionID: String, window: PlanWindow, threshold: Double, now: Date = Date()) -> Bool {
        let key = Key(connectionID: connectionID, label: window.label, threshold: threshold)
        if let entry = announced[key] {
            // A known reset time that has passed means a new window; no reset time means wait for `observe`.
            guard let reset = entry.resetsAt, reset <= now else { return false }
        }
        announced[key] = Entry(resetsAt: window.resetsAt)
        return true
    }

    /// Re-arms thresholds of a window without a reset time once usage has clearly dropped.
    public mutating func observe(connectionID: String, window: PlanWindow) {
        for (key, entry) in announced where key.connectionID == connectionID && key.label == window.label && entry.resetsAt == nil {
            if window.usedPercent < key.threshold - Self.rearmMargin { announced[key] = nil }
        }
    }

    /// Forgets a connection, e.g. when it is removed.
    public mutating func forget(connectionID: String) {
        announced = announced.filter { $0.key.connectionID != connectionID }
    }
}

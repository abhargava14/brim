import Foundation

/// Every tab the open island can show, in the default order.
public enum TabID: String, CaseIterable, Codable, Sendable, Identifiable {
    case home
    case ai
    case analytics
    case notes
    case calendar
    case timers
    case stats
    case screen
    case weather
    case links
    case sounds
    case scratchpad
    case clipboard
    case files
    case units

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: return "Home"
        case .ai: return "AI"
        case .analytics: return "Analytics"
        case .notes: return "Notes"
        case .calendar: return "Calendar"
        case .timers: return "Timers"
        case .stats: return "Stats"
        case .screen: return "Screen Time"
        case .weather: return "Weather"
        case .links: return "Links"
        case .sounds: return "Sounds"
        case .scratchpad: return "Scratchpad"
        case .clipboard: return "Clipboard"
        case .files: return "Files"
        case .units: return "Units"
        }
    }

    /// One line for Settings › Tabs.
    public var blurb: String {
        switch self {
        case .home: return "Now playing, your next event and a launcher"
        case .ai: return "Tokens and plan limits for your coding agents"
        case .analytics: return "Visitors, pages and sources for your sites"
        case .notes: return "Longer thoughts, kept next to the notch"
        case .calendar: return "Seven-day agenda and reminders"
        case .timers: return "Pomodoro, countdown, stopwatch and hydration"
        case .stats: return "CPU, memory, disk, network and battery"
        case .screen: return "Where the day went, app by app"
        case .weather: return "Current conditions and a seven-day forecast"
        case .links: return "Search the web and keep the sites you use"
        case .sounds: return "Rain, brown noise and more, layered"
        case .scratchpad: return "One always-there text box"
        case .clipboard: return "Searchable history of what you copied"
        case .files: return "Convert and shrink images to JPEG, PNG, HEIC or PDF"
        case .units: return "Units and currencies, without a browser tab"
        }
    }

    /// Shown in the tab bar on a fresh install; the rest wait under "More".
    public static let defaultVisible: [TabID] = [.home, .ai, .calendar, .timers, .notes, .stats, .weather, .sounds]
}

/// Which tabs show in the bar and in what order. Hidden tabs stay reachable from "More".
public struct TabLayout: Equatable, Codable, Sendable {
    public var order: [TabID]
    public var hidden: Set<TabID>

    public init(order: [TabID], hidden: Set<TabID>) {
        self.order = order
        self.hidden = hidden
    }

    /// Default visible tabs first, then everything else hidden.
    public static var standard: TabLayout {
        let rest = TabID.allCases.filter { !TabID.defaultVisible.contains($0) }
        return TabLayout(order: TabID.defaultVisible + rest, hidden: Set(rest))
    }

    /// Restores a layout from saved raw values. Unknown IDs are dropped and new tabs are added
    /// hidden at the end, so an update never surprises the bar.
    public init(savedOrder: [String], savedHidden: [String]) {
        guard !savedOrder.isEmpty else {
            self = .standard
            return
        }
        var seen = Set<TabID>()
        var order: [TabID] = []
        for raw in savedOrder {
            guard let id = TabID(rawValue: raw), !seen.contains(id) else { continue }
            seen.insert(id)
            order.append(id)
        }
        var hidden = Set(savedHidden.compactMap(TabID.init(rawValue:)))
        for id in TabID.allCases where !seen.contains(id) {
            order.append(id)
            hidden.insert(id)
        }
        self.init(order: order, hidden: hidden)
        if visible.isEmpty { self.hidden.remove(order[0]) }
    }

    public var visible: [TabID] { order.filter { !hidden.contains($0) } }
    public var more: [TabID] { order.filter { hidden.contains($0) } }

    public func isVisible(_ id: TabID) -> Bool { !hidden.contains(id) }

    /// Moves a tab one place up (-1) or down (+1).
    public mutating func move(_ id: TabID, by offset: Int) {
        guard let index = order.firstIndex(of: id) else { return }
        let target = index + offset
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
    }

    /// Hides or shows a tab. The last visible tab can't be hidden.
    public mutating func setVisible(_ id: TabID, _ visible: Bool) {
        if visible {
            hidden.remove(id)
        } else if self.visible.count > 1 || !isVisible(id) {
            hidden.insert(id)
        }
    }
}

/// The short label that tells two accounts of one tool apart ("personal", "work").
public enum AccountTag {
    /// Splits a connection name like "Claude · Work" into its tool part and tag.
    public static func split(_ name: String) -> (base: String, tag: String?) {
        let parts = name.components(separatedBy: " · ")
        guard parts.count >= 2 else { return (name, nil) }
        let tag = parts.dropFirst().joined(separator: " · ").trimmingCharacters(in: .whitespaces)
        return (parts[0], tag.isEmpty ? nil : tag.lowercased())
    }

    /// Suggested labels, in the order the Add flow offers them.
    public static let suggestions = ["personal", "work", "side project"]
}

extension Connection.Option {
    /// Account label shown as a tag on the account's pill, e.g. "work".
    public static let tag = "tag"
}

extension Connection {
    /// The account's label: the saved tag, or the part after " · " in its name.
    public var tag: String? {
        let saved = option(Option.tag)
        if !saved.isEmpty { return saved.lowercased() }
        return AccountTag.split(name).tag
    }

    /// Sets the label and keeps the display name in step ("Claude · work").
    public mutating func setTag(_ tag: String?) {
        let clean = tag?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        options[Option.tag] = clean.isEmpty ? nil : clean
        let base = AccountTag.split(name).base
        name = clean.isEmpty ? base : "\(base) · \(clean)"
    }
}

/// Daily highest plan-use percentage per account, so quota-only tools get a 14-day chart.
public struct QuotaHistory: Codable, Equatable, Sendable {
    /// Connection ID → day ("yyyy-MM-dd") → highest percent seen that day.
    public var days: [String: [String: Double]] = [:]

    public init() {}

    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Records a reading; returns true when it raised that day's value.
    @discardableResult
    public mutating func record(_ id: String, percent: Double, at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        let day = Self.key(for: date, calendar: calendar)
        var entry = days[id] ?? [:]
        guard percent > (entry[day] ?? -1) else { return false }
        entry[day] = percent
        // Keep about two months per account.
        if entry.count > 62 {
            for old in entry.keys.sorted().prefix(entry.count - 62) { entry[old] = nil }
        }
        days[id] = entry
        return true
    }

    /// The last `count` days ending today, oldest first; days without a reading are nil.
    public func series(_ id: String, days count: Int = 14, now: Date = Date(), calendar: Calendar = .current) -> [Double?] {
        let entry = days[id] ?? [:]
        return (0..<count).reversed().map { back in
            let date = calendar.date(byAdding: .day, value: -back, to: now) ?? now
            return entry[Self.key(for: date, calendar: calendar)]
        }
    }

    public static func load(from url: URL) -> QuotaHistory {
        guard let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode(QuotaHistory.self, from: data) else { return QuotaHistory() }
        return history
    }

    public func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }
}

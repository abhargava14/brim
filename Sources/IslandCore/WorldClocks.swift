import Foundation

/// A city in the Clocks tab: a label and an IANA time zone.
public struct WorldClock: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var zone: String

    public init(id: String = UUID().uuidString, label: String, zone: String) {
        self.id = id
        self.label = label
        self.zone = zone
    }

    public var timeZone: TimeZone { TimeZone(identifier: zone) ?? .current }
}

/// City search, offsets and working-hours hints for the Clocks tab.
public enum WorldClocks {
    /// How many cities fit next to the local clock.
    public static let limit = 3

    /// Names people search for that aren't the zone's own city.
    static let aliases: [(String, String)] = [
        ("San Francisco", "America/Los_Angeles"), ("Seattle", "America/Los_Angeles"), ("Portland", "America/Los_Angeles"),
        ("San Diego", "America/Los_Angeles"), ("Las Vegas", "America/Los_Angeles"), ("SF", "America/Los_Angeles"),
        ("Austin", "America/Chicago"), ("Dallas", "America/Chicago"), ("Houston", "America/Chicago"),
        ("Boston", "America/New_York"), ("Washington", "America/New_York"), ("Miami", "America/New_York"),
        ("Atlanta", "America/New_York"), ("NYC", "America/New_York"), ("Philadelphia", "America/New_York"),
        ("Montreal", "America/Toronto"), ("Ottawa", "America/Toronto"),
        ("Bengaluru", "Asia/Kolkata"), ("Bangalore", "Asia/Kolkata"), ("Mumbai", "Asia/Kolkata"), ("Delhi", "Asia/Kolkata"),
        ("New Delhi", "Asia/Kolkata"), ("Hyderabad", "Asia/Kolkata"), ("Chennai", "Asia/Kolkata"), ("Pune", "Asia/Kolkata"),
        ("India", "Asia/Kolkata"), ("Beijing", "Asia/Shanghai"), ("Shenzhen", "Asia/Shanghai"), ("China", "Asia/Shanghai"),
        ("Osaka", "Asia/Tokyo"), ("Japan", "Asia/Tokyo"), ("Abu Dhabi", "Asia/Dubai"), ("UAE", "Asia/Dubai"),
        ("Melbourne", "Australia/Melbourne"), ("Canberra", "Australia/Sydney"), ("Munich", "Europe/Berlin"),
        ("Frankfurt", "Europe/Berlin"), ("Hamburg", "Europe/Berlin"), ("Barcelona", "Europe/Madrid"),
        ("Milan", "Europe/Rome"), ("Manchester", "Europe/London"), ("Edinburgh", "Europe/London"), ("UK", "Europe/London"),
        ("Tel Aviv", "Asia/Jerusalem"), ("Ho Chi Minh City", "Asia/Ho_Chi_Minh"), ("Saigon", "Asia/Ho_Chi_Minh"),
        ("UTC", "UTC"), ("GMT", "GMT"),
    ]

    /// "America/Los_Angeles" → "Los Angeles".
    public static func city(of zone: String) -> String {
        zone.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zone
    }

    /// Cities matching what was typed, best first: alias and city-name prefixes, then contains.
    public static func search(_ query: String, limit: Int = 6) -> [WorldClock] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var found: [(rank: Int, clock: WorldClock)] = []
        var seen = Set<String>()
        func consider(_ label: String, _ zone: String) {
            let name = label.lowercased()
            let rank: Int
            if name == q { rank = 0 } else if name.hasPrefix(q) { rank = 1 } else if name.contains(q) { rank = 2 } else { return }
            let key = label + "|" + zone
            guard !seen.contains(key), TimeZone(identifier: zone) != nil else { return }
            seen.insert(key)
            found.append((rank, WorldClock(id: key, label: label, zone: zone)))
        }
        for (label, zone) in aliases { consider(label, zone) }
        for zone in TimeZone.knownTimeZoneIdentifiers where zone.contains("/") { consider(city(of: zone), zone) }
        return found.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.clock.label < $1.clock.label }.prefix(limit).map(\.clock)
    }

    /// Seconds a zone is ahead of another at a moment (negative when behind).
    public static func offset(_ zone: TimeZone, from base: TimeZone, at date: Date) -> Int {
        zone.secondsFromGMT(for: date) - base.secondsFromGMT(for: date)
    }

    /// "Same time", "+5h 30m", "−8h".
    public static func offsetText(_ seconds: Int) -> String {
        guard seconds != 0 else { return "Same time" }
        let sign = seconds > 0 ? "+" : "−"
        let minutes = abs(seconds) / 60
        let h = minutes / 60, m = minutes % 60
        return sign + (m == 0 ? "\(h)h" : h == 0 ? "\(m)m" : "\(h)h \(m)m")
    }

    /// "Today", "Tomorrow" or "Yesterday" for the date in a zone, compared with the base zone.
    public static func dayText(_ zone: TimeZone, base: TimeZone, at date: Date) -> String {
        var there = Calendar(identifier: .gregorian)
        there.timeZone = zone
        var here = Calendar(identifier: .gregorian)
        here.timeZone = base
        let a = there.dateComponents([.year, .month, .day], from: date)
        let b = here.dateComponents([.year, .month, .day], from: date)
        guard let dayThere = Calendar(identifier: .gregorian).date(from: a),
              let dayHere = Calendar(identifier: .gregorian).date(from: b) else { return "Today" }
        let diff = Calendar(identifier: .gregorian).dateComponents([.day], from: dayHere, to: dayThere).day ?? 0
        return diff > 0 ? "Tomorrow" : diff < 0 ? "Yesterday" : "Today"
    }

    public enum Hours: Equatable, Sendable {
        case working, evening, asleep

        public var title: String {
            switch self {
            case .working: return "Working hours"
            case .evening: return "Evening"
            case .asleep: return "Night"
            }
        }
    }

    /// Working 9–18, evening 18–23 and 7–9, night otherwise; weekends are never "working".
    public static func hours(in zone: TimeZone, at date: Date) -> Hours {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let hour = calendar.component(.hour, from: date)
        let weekend = calendar.isDateInWeekend(date)
        if (9..<18).contains(hour) { return weekend ? .evening : .working }
        if (7..<9).contains(hour) || (18..<23).contains(hour) { return .evening }
        return .asleep
    }
}

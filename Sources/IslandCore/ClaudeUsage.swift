import Foundation

/// Parses `GET https://api.anthropic.com/api/oauth/usage?at_wall=1&skip_spend=1`, the endpoint
/// Claude Code's `/usage` reads: the current 5-hour session, the weekly limit across all models,
/// and weekly limits for single models. Every percentage is used, as Anthropic reports it.
/// Spend and credit fields are ignored.
public enum ClaudeUsageResponse {
    public static func parse(_ data: Data) -> [PlanWindow]? {
        guard let root = JSON.object(data) else { return nil }
        var windows: [PlanWindow] = []

        if let limits = root["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let percent = JSON.double(limit, "percent") ?? JSON.double(limit, "utilization") else { continue }
                let reset = date(limit["resets_at"])
                switch JSON.string(limit, "kind") {
                case "session":
                    windows.append(PlanWindow(label: "5h", usedPercent: percent, resetsAt: reset))
                case "weekly_all":
                    windows.append(PlanWindow(label: "Week", usedPercent: percent, resetsAt: reset))
                case "weekly_scoped":
                    let scope = limit["scope"] as? [String: Any]
                    let name = JSON.string(scope?["model"] as? [String: Any], "display_name")
                        ?? JSON.string(scope?["surface"] as? [String: Any], "display_name")
                    guard let name else { continue }
                    windows.append(PlanWindow(label: name, usedPercent: percent, resetsAt: reset, model: name))
                default:
                    continue
                }
            }
        }

        if windows.isEmpty {
            let keys = [("five_hour", "5h", nil), ("seven_day", "Week", nil), ("seven_day_opus", "Opus", "Opus"), ("seven_day_sonnet", "Sonnet", "Sonnet")]
            for (key, label, model) in keys {
                guard let window = root[key] as? [String: Any], let percent = JSON.double(window, "utilization") else { continue }
                windows.append(PlanWindow(label: label, usedPercent: percent, resetsAt: date(window["resets_at"]), model: model))
            }
        }
        let known = root["limits"] != nil || ["five_hour", "seven_day"].contains { root.keys.contains($0) }
        return known ? windows : nil
    }

    /// The full view's name for a window: "Current session", "Week · all models", "Week · Opus".
    public static func title(for window: PlanWindow) -> String {
        if let model = window.model { return "Week · \(model)" }
        switch window.label {
        case "5h": return "Current session"
        case "Week": return "Week · all models"
        default: return window.label
        }
    }

    /// Anthropic sends microseconds (`…59.760585+00:00`); ISO8601DateFormatter takes up to milliseconds.
    static func date(_ value: Any?) -> Date? {
        if let seconds = JSON.number(value) { return Date(timeIntervalSince1970: seconds) }
        guard var text = value as? String else { return nil }
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }),
           text.distance(from: dot, to: end) > 4 {
            text.replaceSubrange(text.index(dot, offsetBy: 4)..<end, with: "")
        }
        return JSON.date(text)
    }
}

/// The last limits Anthropic reported for each account, so an idle account whose sign-in has
/// expired can still show them ("as of 2h ago") until they reset. Holds percentages and reset
/// times only, keyed by `ClaudeAccount.key`; no tokens or emails.
public struct ClaudeLimitsCache: Codable, Equatable, Sendable {
    public struct Reading: Codable, Equatable, Sendable {
        public var windows: [PlanWindow]
        public var fetchedAt: Date

        public init(windows: [PlanWindow], fetchedAt: Date) {
            self.windows = windows
            self.fetchedAt = fetchedAt
        }
    }

    public var readings: [String: Reading] = [:]

    public init(readings: [String: Reading] = [:]) {
        self.readings = readings
    }

    public static func load(from url: URL) -> ClaudeLimitsCache {
        guard let data = try? Data(contentsOf: url) else { return ClaudeLimitsCache() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(ClaudeLimitsCache.self, from: data)) ?? ClaudeLimitsCache()
    }

    public func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public static func defaultURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("claude-limits.json")
    }
}

/// Picks the limits to show for one Claude account. Never estimates: a live answer wins, then the
/// running session's status line, then the last answer while it hasn't reset yet, marked as old.
public enum ClaudeLimits {
    public struct Resolved: Equatable, Sendable {
        public var windows: [PlanWindow]
        /// Set when the windows are an older reading.
        public var asOf: Date?
        /// Why the limits are old or missing, e.g. "Open Claude Code once to refresh".
        public var note: String?
    }

    public static func resolve(live: [PlanWindow]?, statusLine: [PlanWindow], cached: ClaudeLimitsCache.Reading?,
                               failure: String?, now: Date = Date()) -> Resolved {
        func current(_ list: [PlanWindow]) -> [PlanWindow] { list.filter { ($0.resetsAt ?? .distantFuture) > now } }
        if let live { return Resolved(windows: current(live), asOf: nil, note: nil) }
        let fromStatusLine = current(statusLine)
        if !fromStatusLine.isEmpty { return Resolved(windows: fromStatusLine, asOf: nil, note: nil) }
        if let cached {
            let old = current(cached.windows)
            if !old.isEmpty { return Resolved(windows: old, asOf: cached.fetchedAt, note: failure) }
        }
        return Resolved(windows: [], asOf: nil, note: failure ?? "Claude didn't report limits for this account.")
    }
}

import Foundation

public enum Format {
    /// `312`, `8.4K`, `1.24M`, `3.1B`.
    public static func tokens(_ value: Int64) -> String {
        let v = Double(value)
        switch value {
        case ..<1_000: return "\(value)"
        case ..<10_000: return String(format: "%.1fK", v / 1_000)
        case ..<1_000_000: return String(format: "%.0fK", v / 1_000)
        case ..<10_000_000: return String(format: "%.2fM", v / 1_000_000)
        case ..<1_000_000_000: return String(format: "%.1fM", v / 1_000_000)
        default: return String(format: "%.2fB", v / 1_000_000_000)
        }
    }

    public static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    /// Time until `date`: `45m`, `2h 10m`, `3d 4h`.
    public static func countdown(to date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
    }

    /// `just now`, `5m ago`, `3h ago`, `2d ago`.
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    /// `claude-sonnet-4-5-20250929` -> `sonnet-4-5`; `gpt-5-codex` stays as is.
    public static func modelName(_ model: String) -> String {
        var name = model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
        if let range = name.range(of: #"-\d{8}$"#, options: .regularExpression) {
            name.removeSubrange(range)
        }
        return name
    }
}

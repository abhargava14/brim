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

    /// How much of a plan window is used, never how much is left: `57% used`, `212 / 300 used`.
    public static func used(_ window: PlanWindow) -> String {
        "\(window.detail ?? percent(window.usedPercent)) used"
    }

    /// Display name for a plan / model window. Claude scopes get “Week · …” titles.
    public static func windowLabel(_ window: PlanWindow, kind: ToolKind? = nil) -> String {
        if kind == .claude { return ClaudeUsageResponse.title(for: window) }
        return window.label
    }

    /// Every plan window with “used” labeling — never collapsed to the tightest alone.
    /// Example: `Cursor models 100% used · Other models 10% used`.
    public static func allUsed(_ windows: [PlanWindow], kind: ToolKind? = nil) -> String {
        windows.map { "\(windowLabel($0, kind: kind)) \(used($0))" }.joined(separator: " · ")
    }

    /// Time until `date`: `45m`, `2h 10m`, `3d 4h`.
    public static func countdown(to date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
    }

    /// `resets in 1h 20m` when it's soon, otherwise the day: `resets Nov 17`.
    public static func reset(_ date: Date, now: Date = Date()) -> String {
        guard date.timeIntervalSince(now) > 2 * 86_400 else { return "resets in \(countdown(to: date, now: now))" }
        return "resets \(dayFormatter.string(from: date))"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

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

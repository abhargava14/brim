import Foundation

/// Agent / screenshot QA switches. Never unlock the Keychain or refresh OAuth during these modes.
public enum BrimQA {
    /// `BRIM_QA_NO_KEYCHAIN=1` or `BRIM_SCREENSHOT=1` — skip Keychain, account fetch, OAuth, and
    /// use fixture island data so interactive password prompts cannot appear.
    public static var skipCredentials: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["BRIM_QA_NO_KEYCHAIN"] == "1" || env["BRIM_SCREENSHOT"] == "1"
    }

    /// Compact equal-height fixture: Claude Code (3 windows) + Cursor (2) + Claude (2).
    public static func fixtureSnapshot() -> UsageSnapshot {
        let now = Date()
        var claudeCode = ToolSnapshot(id: "qa-claude-code", kind: .claude, name: "Claude Code")
        claudeCode.hasData = true
        claudeCode.planName = "Team"
        claudeCode.today = TokenCounts(input: 2_000_000, output: 2_320_000)
        claudeCode.updatedAt = now.addingTimeInterval(-180)
        claudeCode.planWindows = [
            PlanWindow(label: "Current session", usedPercent: 13, resetsAt: nil),
            PlanWindow(label: "Week · all models", usedPercent: 70, resetsAt: now.addingTimeInterval(86400 * 4)),
            PlanWindow(label: "Week · Fable", usedPercent: 0, resetsAt: now.addingTimeInterval(86400 * 4), model: "Fable"),
        ]

        var cursor = ToolSnapshot(id: "qa-cursor", kind: .cursor, name: "Cursor")
        cursor.hasData = true
        cursor.planName = "Pro+"
        cursor.updatedAt = now.addingTimeInterval(-180)
        cursor.planWindows = [
            PlanWindow(label: "Cursor models", usedPercent: 11, resetsAt: now.addingTimeInterval(86400 * 20)),
            PlanWindow(label: "Other models", usedPercent: 100, resetsAt: now.addingTimeInterval(86400 * 20)),
        ]

        var claude = ToolSnapshot(id: "qa-claude", kind: .claude, name: "Claude")
        claude.hasData = true
        claude.planName = "Pro"
        claude.updatedAt = now.addingTimeInterval(-600)
        claude.planWindows = [
            PlanWindow(label: "Current session", usedPercent: 0, resetsAt: nil),
            PlanWindow(label: "Week · all models", usedPercent: 2, resetsAt: now.addingTimeInterval(86400 * 5)),
        ]

        return UsageSnapshot(tools: [claudeCode, cursor, claude], generatedAt: now)
    }
}

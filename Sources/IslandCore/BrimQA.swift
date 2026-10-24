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

        guard ProcessInfo.processInfo.environment["BRIM_QA_FIXTURE"] == "rich" else {
            return UsageSnapshot(tools: [claudeCode, cursor, claude], generatedAt: now)
        }
        // Richer set for the tabbed island: history, a working session and a broken account.
        let calendar = Calendar.current
        func history(_ base: Double, _ seed: Double) -> [DailyPoint] {
            (0..<14).map { back in
                let value = base * (0.5 + 0.35 * sin(Double(back) * 0.55 + seed) + 0.15 * sin(Double(back) * 1.7 + seed * 3))
                let date = calendar.date(byAdding: .day, value: -(13 - back), to: calendar.startOfDay(for: now)) ?? now
                return DailyPoint(date: date, tokens: TokenCounts(input: Int64(value * 0.01), output: Int64(value * 0.03),
                                                                  cacheWrite: Int64(value * 0.12), cacheRead: Int64(value * 0.84)))
            }
        }
        claudeCode.name = "Claude · personal"
        claudeCode.today = TokenCounts(input: 2_100, output: 310_000, cacheWrite: 1_900_000, cacheRead: 11_900_000)
        claudeCode.todayRequests = 212
        claudeCode.todaySessions = 3
        claudeCode.topModel = "claude-sonnet-4-5"
        claudeCode.planName = "Max 5×"
        claudeCode.daily = history(14_000_000, 1)
        claudeCode.lastActivity = now.addingTimeInterval(-20)
        claudeCode.sessions = [SessionUsage(id: "s1", project: "auth-service", model: "claude-sonnet-4-5",
                                            today: claudeCode.today, requests: 212, lastActivity: now.addingTimeInterval(-20))]
        claudeCode.planWindows = [
            PlanWindow(label: "Current session", usedPercent: 84, resetsAt: now.addingTimeInterval(4_800)),
            PlanWindow(label: "Week · all models", usedPercent: 31, resetsAt: now.addingTimeInterval(86400 * 3 + 14_400)),
        ]
        var codex = ToolSnapshot(id: "qa-codex", kind: .codex, name: "Codex · work")
        codex.hasData = true
        codex.planName = "Business"
        codex.today = TokenCounts(input: 400_000, output: 260_000, cacheWrite: 0, cacheRead: 2_440_000)
        codex.todayRequests = 64
        codex.todaySessions = 2
        codex.topModel = "gpt-5-codex"
        codex.daily = history(3_100_000, 4)
        codex.updatedAt = now.addingTimeInterval(-60)
        codex.planWindows = [
            PlanWindow(label: "5h", usedPercent: 22, resetsAt: now.addingTimeInterval(9_000)),
            PlanWindow(label: "Week", usedPercent: 9, resetsAt: now.addingTimeInterval(86400 * 5)),
        ]
        var copilot = ToolSnapshot(id: "qa-copilot", kind: .copilot, name: "GitHub Copilot")
        copilot.statusMessage = "Session expired. Sign in again."
        copilot.updatedAt = now.addingTimeInterval(-3_600)
        cursor.name = "Cursor · work"
        return UsageSnapshot(tools: [claudeCode, codex, cursor, claude, copilot], generatedAt: now)
    }
}

import Foundation

/// Reads Codex rollout files (`~/.codex/sessions/yyyy/MM/dd/rollout-*.jsonl`).
///
/// Keeps per-file state (session, model, cumulative total), so use one instance per file and
/// feed it lines in order. Only metadata, token counters and rate limits are read.
public final class CodexLogParser {
    public private(set) var sessionID: String?
    public private(set) var model: String?
    public private(set) var cwd: String?
    /// The primary (usually 5-hour) rate-limit window and when it was observed.
    public private(set) var primary: (window: PlanWindow, observedAt: Date)?
    /// The secondary (usually weekly) window.
    public private(set) var secondary: (window: PlanWindow, observedAt: Date)?

    /// Newer Codex builds write `token_usage_record` lines; `token_count` then only carries rate limits.
    private var hasUsageRecords = false
    /// Last cumulative total of a `token_count` event; Codex re-emits unchanged totals.
    private var lastTotal: Int64 = 0

    public init() {}

    public func parse(_ line: String) -> UsageEvent? {
        guard line.utf8.count >= 16 else { return nil }
        // Skip the large content lines (messages, reasoning, tool output) without parsing them.
        guard line.contains("\"token_usage_record\"")
            || line.contains("\"token_count\"")
            || line.contains("\"session_meta\"")
            || line.contains("\"turn_context\"")
        else { return nil }

        guard let root = JSON.object(line), let payload = root["payload"] as? [String: Any] else { return nil }

        switch JSON.string(root, "type") {
        case "session_meta":
            sessionID = JSON.string(payload, "id") ?? JSON.string(payload, "session_id") ?? sessionID
            cwd = JSON.string(payload, "cwd") ?? cwd
            model = JSON.string(payload, "model") ?? model
            return nil
        case "turn_context":
            model = JSON.string(payload, "model") ?? model
            cwd = JSON.string(payload, "cwd") ?? cwd
            return nil
        case "token_usage_record":
            return parseUsageRecord(root: root, payload: payload)
        case "event_msg" where JSON.string(payload, "type") == "token_count":
            return parseTokenCount(root: root, payload: payload)
        default:
            return nil
        }
    }

    private func parseUsageRecord(root: [String: Any], payload: [String: Any]) -> UsageEvent? {
        guard let usage = payload["usage"] as? [String: Any], let timestamp = JSON.date(root["timestamp"]) else { return nil }
        let tokens = Self.tokens(from: usage)
        guard !tokens.isZero else { return nil }
        hasUsageRecords = true
        if sessionID == nil { sessionID = JSON.string(payload, "session_id") }
        let key = JSON.string(payload, "response_id")
            ?? "\(JSON.string(payload, "turn_id") ?? ""):\(timestamp.timeIntervalSince1970)"
        return event(key: key, timestamp: timestamp, tokens: tokens)
    }

    private func parseTokenCount(root: [String: Any], payload: [String: Any]) -> UsageEvent? {
        let timestamp = JSON.date(root["timestamp"])
        if let timestamp { readRateLimits(payload, observedAt: timestamp) }

        guard let info = payload["info"] as? [String: Any] else { return nil }
        let total = JSON.int(info["total_token_usage"] as? [String: Any], "total_tokens")
        guard !hasUsageRecords, total > 0, total != lastTotal,
              let last = info["last_token_usage"] as? [String: Any],
              let timestamp
        else { return nil }

        let tokens = Self.tokens(from: last)
        guard !tokens.isZero else { return nil }
        lastTotal = total
        return event(key: "\(sessionID ?? "?"):total:\(total)", timestamp: timestamp, tokens: tokens)
    }

    private func readRateLimits(_ payload: [String: Any], observedAt: Date) {
        guard let limits = payload["rate_limits"] as? [String: Any] else { return }
        if let limitID = JSON.string(limits, "limit_id"), limitID != "codex" { return }

        if let window = Self.window(limits["primary"] as? [String: Any], observedAt: observedAt),
           observedAt >= (primary?.observedAt ?? .distantPast) {
            primary = (window, observedAt)
        }
        if let window = Self.window(limits["secondary"] as? [String: Any], observedAt: observedAt),
           observedAt >= (secondary?.observedAt ?? .distantPast) {
            secondary = (window, observedAt)
        }
    }

    static func window(_ dict: [String: Any]?, observedAt: Date) -> PlanWindow? {
        guard let dict,
              let percent = JSON.double(dict, "used_percent"), percent >= 0, percent <= 100
        else { return nil }
        let minutes = Int(JSON.int(dict, "window_minutes"))
        var resetsAt = JSON.unixDate(dict, "resets_at")
        if resetsAt == nil, let seconds = JSON.double(dict, "resets_in_seconds"), seconds >= 0 {
            resetsAt = observedAt.addingTimeInterval(seconds)
        }
        return PlanWindow(label: label(forWindowMinutes: minutes), usedPercent: percent, resetsAt: resetsAt)
    }

    static func label(forWindowMinutes minutes: Int) -> String {
        switch minutes {
        case 10_080: return "Week"
        case 1_440: return "Day"
        case let m where m >= 60 && m % 60 == 0: return "\(m / 60)h"
        case let m where m > 0: return "\(m)m"
        default: return "Limit"
        }
    }

    /// OpenAI counts cached input inside `input_tokens`; split it out so nothing is counted twice.
    static func tokens(from usage: [String: Any]) -> TokenCounts {
        let input = JSON.int(usage, "input_tokens")
        let cached = min(JSON.int(usage, "cached_input_tokens"), input)
        let cacheWrite = min(JSON.int(usage, "cache_write_input_tokens"), input - cached)
        return TokenCounts(
            input: input - cached - cacheWrite,
            output: JSON.int(usage, "output_tokens"),
            cacheWrite: cacheWrite,
            cacheRead: cached
        )
    }

    private func event(key: String, timestamp: Date, tokens: TokenCounts) -> UsageEvent {
        UsageEvent(
            format: .codex,
            key: key,
            timestamp: timestamp,
            model: model ?? "unknown",
            tokens: tokens,
            sessionID: sessionID,
            project: projectName(fromPath: cwd)
        )
    }
}

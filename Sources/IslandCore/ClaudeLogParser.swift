import Foundation

/// Reads one line of a Claude Code transcript (`~/.claude/projects/**/*.jsonl`).
///
/// Only `usage`, `model`, identifiers, timestamp and working directory are read; message
/// content is never touched. Claude Code writes one line per content block and every line
/// repeats the same usage, so events are keyed by `message.id` + `requestId` and must be
/// de-duplicated by the caller.
public enum ClaudeLogParser {
    public static func parse(_ line: String) -> UsageEvent? {
        // Cheap pre-filter: most lines are user turns, tool results and snapshots.
        guard line.utf8.count > 32, line.contains("\"usage\""), line.contains("\"assistant\"") else { return nil }

        guard let root = JSON.object(line),
              JSON.string(root, "type") == "assistant",
              let message = root["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = JSON.string(message, "model"), model != "<synthetic>",
              let timestamp = JSON.date(root["timestamp"])
        else { return nil }

        let tokens = TokenCounts(
            input: JSON.int(usage, "input_tokens"),
            output: JSON.int(usage, "output_tokens"),
            cacheWrite: JSON.int(usage, "cache_creation_input_tokens"),
            cacheRead: JSON.int(usage, "cache_read_input_tokens")
        )
        guard !tokens.isZero else { return nil }

        let messageID = JSON.string(message, "id")
        let requestID = JSON.string(root, "requestId")
        let key: String
        if messageID == nil && requestID == nil {
            key = JSON.string(root, "uuid") ?? "\(timestamp.timeIntervalSince1970):\(tokens.total)"
        } else {
            key = "\(messageID ?? ""):\(requestID ?? "")"
        }

        return UsageEvent(
            format: .claude,
            key: key,
            timestamp: timestamp,
            model: model,
            tokens: tokens,
            sessionID: JSON.string(root, "sessionId"),
            project: projectName(fromPath: JSON.string(root, "cwd"))
        )
    }
}

/// Plan usage Claude Code hands to its status line command: `rate_limits.five_hour` and
/// `rate_limits.seven_day`, each with `used_percentage` (0-100) and `resets_at` (Unix seconds).
/// Present only for Claude subscribers, after the first response of a session.
public enum ClaudeStatusLine {
    public static func planWindows(from data: Data) -> [PlanWindow] {
        guard let root = JSON.object(data), let limits = root["rate_limits"] as? [String: Any] else { return [] }
        return [("five_hour", "5h"), ("seven_day", "Week")].compactMap { key, label in
            guard let window = limits[key] as? [String: Any],
                  let percent = JSON.double(window, "used_percentage")
            else { return nil }
            return PlanWindow(label: label, usedPercent: percent, resetsAt: JSON.unixDate(window, "resets_at"))
        }
    }
}

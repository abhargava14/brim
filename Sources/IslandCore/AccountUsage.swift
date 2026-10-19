import Foundation

/// Plan and allowance usage as reported by a tool's account service.
public struct AccountUsage: Equatable, Sendable {
    public var planName: String?
    public var windows: [PlanWindow]
    public var fetchedAt: Date

    public init(planName: String?, windows: [PlanWindow], fetchedAt: Date = Date()) {
        self.planName = planName
        self.windows = windows
        self.fetchedAt = fetchedAt
    }
}

// MARK: - GitHub Copilot

/// Parses `GET https://api.github.com/copilot_internal/user`, the endpoint Copilot's own editor
/// extensions use to show the plan and the monthly premium-request allowance.
public enum CopilotUsage {
    public static func parse(_ data: Data, now: Date = Date()) -> AccountUsage? {
        guard let root = JSON.object(data) else { return nil }
        let plan = planName(JSON.string(root, "copilot_plan") ?? JSON.string(root, "access_type_sku"))
        var windows: [PlanWindow] = []

        if let snapshots = root["quota_snapshots"] as? [String: Any] {
            let reset = JSON.dayOrISODate(root["quota_reset_date_utc"]) ?? JSON.dayOrISODate(root["quota_reset_date"])
            for (key, label) in [("premium_interactions", "Premium"), ("chat", "Chat"), ("completions", "Completions")] {
                guard let quota = snapshots[key] as? [String: Any], (quota["unlimited"] as? Bool) != true,
                      let entitlement = JSON.double(quota, "entitlement"), entitlement > 0
                else { continue }
                let remaining = JSON.double(quota, "remaining")
                    ?? JSON.double(quota, "percent_remaining").map { entitlement * $0 / 100 }
                    ?? entitlement
                let used = max(0, entitlement - remaining)
                windows.append(PlanWindow(label: label, usedPercent: used / entitlement * 100, resetsAt: reset,
                                          detail: "\(Int(used.rounded())) / \(Int(entitlement))"))
            }
        } else if let monthly = root["monthly_quotas"] as? [String: Any], let left = root["limited_user_quotas"] as? [String: Any] {
            // Copilot Free reports fixed monthly quotas and what is left of them.
            let reset = JSON.dayOrISODate(root["limited_user_reset_date"])
            for (key, label) in [("chat", "Chat"), ("completions", "Completions")] {
                guard let total = JSON.double(monthly, key), total > 0 else { continue }
                let used = max(0, total - (JSON.double(left, key) ?? total))
                windows.append(PlanWindow(label: label, usedPercent: used / total * 100, resetsAt: reset,
                                          detail: "\(Int(used)) / \(Int(total))"))
            }
        }

        guard plan != nil || !windows.isEmpty else { return nil }
        return AccountUsage(planName: plan, windows: windows, fetchedAt: now)
    }

    static func planName(_ raw: String?) -> String? {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return nil }
        if raw.contains("free") { return "Free" }
        if raw.contains("pro_plus") || raw.contains("proplus") || raw == "individual_pro" { return "Pro+" }
        if raw.contains("enterprise") { return "Enterprise" }
        if raw.contains("business") { return "Business" }
        if raw.contains("individual") || raw.contains("pro") { return "Pro" }
        return raw.capitalized
    }
}

// MARK: - Cursor

/// Parses Cursor's dashboard usage endpoints (private API; may change without notice).
public enum CursorUsage {
    /// The user ID inside Cursor's access token (`sub` claim, e.g. `auth0|user_123` -> `user_123`).
    public static func userID(fromAccessToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload), let claims = JSON.object(data),
              let sub = JSON.string(claims, "sub")
        else { return nil }
        return sub.split(separator: "|").last.map(String.init)
    }

    /// `GET https://cursor.com/api/usage-summary`: included usage of the current billing cycle.
    public static func parseSummary(_ data: Data, now: Date = Date()) -> AccountUsage? {
        guard let root = JSON.object(data) else { return nil }
        let reset = JSON.dayOrISODate(root["billingCycleEnd"])
        var windows: [PlanWindow] = []
        if let individual = root["individualUsage"] as? [String: Any] {
            if let plan = individual["plan"] as? [String: Any], let window = allowance(plan, label: "Included", reset: reset) {
                windows.append(window)
            }
            if let onDemand = individual["onDemand"] as? [String: Any], (onDemand["enabled"] as? Bool) != false,
               let window = allowance(onDemand, label: "On-demand", reset: reset) {
                windows.append(window)
            }
        }
        let plan = JSON.string(root, "membershipType").map(planName)
        guard plan != nil || !windows.isEmpty else { return nil }
        return AccountUsage(planName: plan, windows: windows, fetchedAt: now)
    }

    /// `GET https://cursor.com/api/usage?user=…`: request counts per model (older request-based plans).
    public static func parseRequests(_ data: Data, membership: String?, now: Date = Date()) -> AccountUsage? {
        guard let root = JSON.object(data) else { return nil }
        let start = JSON.dayOrISODate(root["startOfMonth"])
        let reset = start.flatMap { Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: $0) }
        var windows: [PlanWindow] = []
        for key in root.keys.sorted() {
            guard let model = root[key] as? [String: Any],
                  let limit = JSON.double(model, "maxRequestUsage"), limit > 0
            else { continue }
            let used = JSON.double(model, "numRequests") ?? 0
            windows.append(PlanWindow(label: "Requests", usedPercent: used / limit * 100, resetsAt: reset,
                                      detail: "\(Int(used)) / \(Int(limit))"))
        }
        guard !windows.isEmpty else { return nil }
        return AccountUsage(planName: membership.map(planName), windows: windows, fetchedAt: now)
    }

    static func allowance(_ dict: [String: Any], label: String, reset: Date?) -> PlanWindow? {
        guard let limit = JSON.double(dict, "limit"), limit > 0 else { return nil }
        let used = JSON.double(dict, "used") ?? (limit - (JSON.double(dict, "remaining") ?? limit))
        return PlanWindow(label: label, usedPercent: used / limit * 100, resetsAt: reset)
    }

    static func planName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "free", "hobby", "free_trial": return "Hobby"
        case "pro": return "Pro"
        case "pro_plus", "pro+", "proplus": return "Pro+"
        case "ultra": return "Ultra"
        case "business", "team", "teams", "enterprise": return "Teams"
        default: return raw.capitalized
        }
    }
}

// MARK: - Windsurf

/// Parses Windsurf's `GetUserStatus` response (private API; may change without notice).
/// Field names are looked up anywhere in the response, since its nesting has changed over time.
public enum WindsurfUsage {
    public static func parse(_ data: Data, now: Date = Date()) -> AccountUsage? {
        guard let root = JSON.object(data) else { return nil }
        let plan = JSON.find("planName", in: root) as? String
        let reset = JSON.dayOrISODate(JSON.find("planEnd", in: root))
        var windows: [PlanWindow] = []
        for (prefix, label) in [("Prompt", "Credits"), ("Flex", "Flex credits")] {
            guard let available = JSON.number(JSON.find("available\(prefix)Credits", in: root)), available > 0 else { continue }
            let used = JSON.number(JSON.find("used\(prefix)Credits", in: root)) ?? 0
            windows.append(PlanWindow(label: label, usedPercent: used / available * 100, resetsAt: reset))
        }
        guard plan != nil || !windows.isEmpty else { return nil }
        return AccountUsage(planName: plan, windows: windows, fetchedAt: now)
    }
}

// MARK: - OpenRouter and custom endpoints

/// Reads used / limit values from any JSON response using dot paths such as `data.usage`.
public struct EndpointUsage: Equatable, Sendable {
    public var usedPath: String
    public var limitPath: String
    public var planPath: String
    public var resetPath: String
    public var label: String

    public init(usedPath: String, limitPath: String, planPath: String = "", resetPath: String = "", label: String = "Usage") {
        self.usedPath = usedPath
        self.limitPath = limitPath
        self.planPath = planPath
        self.resetPath = resetPath
        self.label = label
    }

    /// OpenRouter's documented `GET https://openrouter.ai/api/v1/key`: credits used against the key's limit.
    public static let openRouter = EndpointUsage(usedPath: "data.usage", limitPath: "data.limit", planPath: "data.label", label: "Credits")

    public func parse(_ data: Data, now: Date = Date()) -> AccountUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) else { return nil }
        let used = JSON.number(Self.value(at: usedPath, in: root))
        let limit = JSON.number(Self.value(at: limitPath, in: root))
        let plan = Self.value(at: planPath, in: root).map { "\($0)" }
        let reset = JSON.dayOrISODate(Self.value(at: resetPath, in: root))
        guard used != nil || plan != nil else { return nil }

        var windows: [PlanWindow] = []
        if let used, let limit, limit > 0 {
            windows.append(PlanWindow(label: label, usedPercent: used / limit * 100, resetsAt: reset,
                                      detail: "\(Self.short(used)) / \(Self.short(limit))"))
        } else if let used {
            // No limit (e.g. prepaid credits): show the amount only.
            windows.append(PlanWindow(label: label, usedPercent: 0, resetsAt: reset, detail: Self.short(used)))
        }
        return AccountUsage(planName: plan, windows: windows, fetchedAt: now)
    }

    /// `data.items.0.used` style lookup; numeric parts index into arrays.
    static func value(at path: String, in root: Any) -> Any? {
        let parts = path.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return nil }
        var current: Any? = root
        for part in parts {
            if let dict = current as? [String: Any] {
                current = dict[part]
            } else if let array = current as? [Any], let index = Int(part), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        return current is NSNull ? nil : current
    }

    static func short(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(format: "%.2f", value)
    }
}

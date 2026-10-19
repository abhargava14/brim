import Foundation

/// How a plan is billed, which decides what the island leads with.
public enum Billing: String, Sendable {
    /// A subscription with rolling usage windows (Claude Pro/Max, ChatGPT Plus/Pro): show plan %.
    case usageWindows
    /// A monthly allowance of requests or credits (Copilot, Cursor, Windsurf): show % of allowance.
    case allowance
    /// Pay per token through an API key: show tokens used.
    case payAsYouGo
}

public struct PlanTier: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let billing: Billing

    public init(id: String, name: String, billing: Billing) {
        self.id = id
        self.name = name
        self.billing = billing
    }
}

/// The plans each tool offers, for the plan picker in Settings. Limits are never hard-coded here:
/// the numbers always come from the tool or its service.
public enum Plans {
    public static let automatic = "auto"

    public static func options(for kind: ToolKind) -> [PlanTier] {
        switch kind {
        case .claude:
            return [
                PlanTier(id: "pro", name: "Pro", billing: .usageWindows),
                PlanTier(id: "max5", name: "Max 5×", billing: .usageWindows),
                PlanTier(id: "max20", name: "Max 20×", billing: .usageWindows),
                PlanTier(id: "team", name: "Team / Enterprise", billing: .usageWindows),
                PlanTier(id: "api", name: "API key (pay as you go)", billing: .payAsYouGo),
            ]
        case .codex:
            return [
                PlanTier(id: "plus", name: "ChatGPT Plus", billing: .usageWindows),
                PlanTier(id: "pro", name: "ChatGPT Pro", billing: .usageWindows),
                PlanTier(id: "business", name: "Business / Enterprise", billing: .usageWindows),
                PlanTier(id: "api", name: "API key (pay as you go)", billing: .payAsYouGo),
            ]
        case .cursor:
            return [
                PlanTier(id: "hobby", name: "Hobby", billing: .allowance),
                PlanTier(id: "pro", name: "Pro", billing: .allowance),
                PlanTier(id: "proplus", name: "Pro+", billing: .allowance),
                PlanTier(id: "ultra", name: "Ultra", billing: .allowance),
                PlanTier(id: "teams", name: "Teams", billing: .allowance),
            ]
        case .windsurf:
            return [
                PlanTier(id: "free", name: "Free", billing: .allowance),
                PlanTier(id: "pro", name: "Pro", billing: .allowance),
                PlanTier(id: "teams", name: "Teams", billing: .allowance),
                PlanTier(id: "enterprise", name: "Enterprise", billing: .allowance),
            ]
        case .copilot:
            return [
                PlanTier(id: "free", name: "Free", billing: .allowance),
                PlanTier(id: "pro", name: "Pro", billing: .allowance),
                PlanTier(id: "proplus", name: "Pro+", billing: .allowance),
                PlanTier(id: "business", name: "Business", billing: .allowance),
                PlanTier(id: "enterprise", name: "Enterprise", billing: .allowance),
            ]
        case .openrouter:
            return [
                PlanTier(id: "credits", name: "Prepaid credits", billing: .payAsYouGo),
                PlanTier(id: "limit", name: "Key with a spending limit", billing: .allowance),
            ]
        case .customLogs, .customEndpoint:
            return [
                PlanTier(id: "subscription", name: "Subscription with limits", billing: .usageWindows),
                PlanTier(id: "allowance", name: "Monthly allowance", billing: .allowance),
                PlanTier(id: "payg", name: "Pay as you go", billing: .payAsYouGo),
            ]
        }
    }

    public static func tier(_ id: String?, for kind: ToolKind) -> PlanTier? {
        guard let id, id != automatic else { return nil }
        return options(for: kind).first { $0.id == id }
    }

    /// The billing of a connection: its chosen plan's, or a sensible default when on automatic.
    public static func billing(for connection: Connection) -> Billing {
        if let tier = tier(connection.planID, for: connection.kind) { return tier.billing }
        switch connection.kind.source {
        case .account: return connection.kind == .openrouter ? .payAsYouGo : .allowance
        case .localLogs: return .usageWindows
        }
    }
}

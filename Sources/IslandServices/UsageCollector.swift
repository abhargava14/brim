import Foundation
import IslandCore

/// Shared log-scan + Claude-limits attachment used by BrimApp and `brim` so merge rules cannot drift.
public enum UsageCollector {
    public static var defaultCheckpointURL: URL {
        UsageCheckpoint.defaultURL(supportDirectory: ClaudeStatusLineSetup.defaultSupportDirectory)
    }

    /// Claude Code's status line reports plan limits for the default folder only.
    public static func externalPlanWindows(
        connections: [Connection],
        statusLineWindows: [PlanWindow]
    ) -> [String: [PlanWindow]] {
        Dictionary(
            connections.filter { $0.kind == .claude && $0.usesDefaultLocation }.map { ($0.id, statusLineWindows) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Configures `engine`, scans, and returns one `ToolSnapshot` per log connection (names/kinds filled in).
    @discardableResult
    public static func scanLogs(
        engine: UsageEngine,
        connections: [Connection],
        statusLineWindows: [PlanWindow]
    ) -> [ToolSnapshot] {
        let logConnections = connections.filter { $0.isEnabled && $0.kind.source == .localLogs }
        let sources = logConnections.compactMap { c in c.logSource().map { (id: c.id, source: $0) } }
        engine.configure(sources)
        engine.externalPlanWindows = externalPlanWindows(connections: logConnections, statusLineWindows: statusLineWindows)
        engine.scan()
        let byID = Dictionary(uniqueKeysWithValues: logConnections.map { ($0.id, $0) })
        return engine.snapshot().map { tool in
            var copy = tool
            if let connection = byID[tool.id] {
                copy.kind = connection.kind
                copy.name = connection.name
            }
            return copy
        }
    }

    /// Applies live / status-line / cached Claude limits onto a log snapshot (same rules as the island).
    public static func applyClaudeLimits(
        to tool: inout ToolSnapshot,
        account: ClaudeAccount?,
        live: [PlanWindow]?,
        cached: ClaudeLimitsCache.Reading?,
        failure: String?,
        planName: String?
    ) {
        guard let account else { return }
        tool.accountLabel = account.email
        if tool.planName == nil { tool.planName = planName ?? account.planLabel }
        let resolved = ClaudeLimits.resolve(live: live, statusLine: tool.planWindows, cached: cached, failure: failure)
        tool.planWindows = resolved.windows
        tool.limitsAsOf = resolved.asOf
        tool.limitsNote = resolved.note
    }

    /// One-shot collection for the CLI: scan logs (with checkpoint), fetch accounts and Claude limits.
    public static func collect(
        connections: [Connection],
        historyDays: Int,
        checkpointURL: URL = UsageCollector.defaultCheckpointURL,
        statusLine: ClaudeStatusLineSetup = ClaudeStatusLineSetup(
            supportDirectory: ClaudeStatusLineSetup.defaultSupportDirectory,
            settingsURL: ClaudeStatusLineSetup.defaultSettingsURL()
        )
    ) async -> (tools: [ToolSnapshot], coveredIDs: Set<String>) {
        let enabled = connections.filter(\.isEnabled)
        let engine = UsageEngine(historyDays: historyDays, checkpointURL: checkpointURL)
        let logTools = Dictionary(
            uniqueKeysWithValues: scanLogs(
                engine: engine,
                connections: enabled,
                statusLineWindows: statusLine.planWindows()
            ).map { ($0.id, $0) }
        )

        let accounts = await withTaskGroup(of: (String, Result<AccountUsage, Error>).self) { group -> [String: Result<AccountUsage, Error>] in
            for connection in enabled where connection.kind.source == .account {
                group.addTask {
                    do { return (connection.id, .success(try await AccountFetcher.fetch(connection))) }
                    catch { return (connection.id, .failure(error)) }
                }
            }
            var results: [String: Result<AccountUsage, Error>] = [:]
            for await (id, result) in group { results[id] = result }
            return results
        }

        let claude = await fetchClaudeLimits(enabled)
        let cacheURL = ClaudeLimitsCache.defaultURL(supportDirectory: statusLine.supportDirectory)
        var cache = ClaudeLimitsCache.load(from: cacheURL)
        for entry in claude.values {
            if case .success(let windows) = entry.result {
                cache.readings[entry.account.key] = .init(windows: windows, fetchedAt: Date())
            }
        }
        if claude.values.contains(where: { if case .success = $0.result { return true } else { return false } }) {
            cache.save(to: cacheURL)
        }

        var tools: [ToolSnapshot] = []
        for connection in enabled {
            if var tool = logTools[connection.id] {
                if let plan = Plans.tier(connection.planID, for: connection.kind)?.name {
                    tool.planName = plan
                }
                if let entry = claude[connection.id] {
                    let live = try? entry.result.get()
                    var failure: String?
                    if case .failure(let error) = entry.result { failure = error.localizedDescription }
                    applyClaudeLimits(
                        to: &tool,
                        account: entry.account,
                        live: live,
                        cached: cache.readings[entry.account.key],
                        failure: failure,
                        planName: tool.planName
                    )
                }
                if !tool.hasData {
                    tool.statusMessage = "No logs found"
                }
                tools.append(tool)
                continue
            }

            var tool: ToolSnapshot
            switch accounts[connection.id] {
            case .success(let usage):
                tool = .account(id: connection.id, kind: connection.kind, name: connection.name,
                                usage: usage, statusMessage: nil)
            case .failure(let error):
                tool = .account(id: connection.id, kind: connection.kind, name: connection.name,
                                usage: nil, statusMessage: error.localizedDescription)
            case nil:
                tool = ToolSnapshot(id: connection.id, kind: connection.kind, name: connection.name)
                tool.statusMessage = "Not checked"
            }
            if let plan = Plans.tier(connection.planID, for: connection.kind)?.name {
                tool.planName = plan
            }
            tools.append(tool)
        }

        let sources = enabled.compactMap { c in c.logSource().map { (id: c.id, source: $0) } }
        return (tools, LogSource.coveredIDs(in: sources))
    }

    private static func fetchClaudeLimits(
        _ connections: [Connection]
    ) async -> [String: (account: ClaudeAccount, result: Result<[PlanWindow], Error>)] {
        await withTaskGroup(of: (String, ClaudeAccount, Result<[PlanWindow], Error>).self) { group in
            for connection in connections where connection.kind == .claude {
                guard let dir = connection.claudeConfigDir() else { continue }
                group.addTask {
                    let account = ClaudeAccounts.account(configDir: dir)
                    do { return (connection.id, account, .success(try await ClaudeUsageFetcher.fetch(account))) }
                    catch { return (connection.id, account, .failure(error)) }
                }
            }
            var results: [String: (account: ClaudeAccount, result: Result<[PlanWindow], Error>)] = [:]
            for await (id, account, result) in group { results[id] = (account, result) }
            return results
        }
    }
}

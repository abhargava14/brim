import Foundation

/// Scans log folders incrementally and keeps per-day totals in memory, separately for every
/// log-based connection (there can be any number of them).
///
/// Not thread-safe: call every method from the same serial queue.
public final class UsageEngine: @unchecked Sendable {
    /// Read position and parser state of one log file within one connection.
    private final class FileCursor {
        let connectionID: String
        let format: LogFormat
        var offset: UInt64 = 0
        var remainder = Data()
        var codex: CodexLogParser?

        init(connectionID: String, format: LogFormat) {
            self.connectionID = connectionID
            self.format = format
            if format == .codex { codex = CodexLogParser() }
        }
    }

    private struct DayAggregate {
        var tokens = TokenCounts.zero
        var requests = 0
        var sessions = Set<String>()
        var modelTokens: [String: TokenCounts] = [:]
        var sessionUsage: [String: SessionAggregate] = [:]
    }

    private struct SessionAggregate {
        var project: String?
        var model: String?
        var latest = Date.distantPast
        var tokens = TokenCounts.zero
        var requests = 0
    }

    private struct RecentEvent {
        let timestamp: Date
        let tokens: TokenCounts
    }

    /// Everything the engine knows about one connection.
    private struct ConnectionState {
        var fileCount = 0
        var seenKeys = Set<String>()
        var days: [Int: DayAggregate] = [:]
        var recent: [RecentEvent] = []
        var lastActivity: Date?
        /// When each session's transcript was last written, which also covers tool runs and prompts.
        var transcriptWrites: [String: Date] = [:]
        var codexPrimary: (window: PlanWindow, observedAt: Date)?
        var codexSecondary: (window: PlanWindow, observedAt: Date)?
    }

    public let historyDays: Int
    private let calendar: Calendar
    private let now: () -> Date

    private var sources: [String: LogSource] = [:]
    private var order: [String] = []
    private var cursors: [String: FileCursor] = [:]
    private var states: [String: ConnectionState] = [:]

    /// Plan windows reported outside the logs (Claude's status line), per connection ID.
    public var externalPlanWindows: [String: [PlanWindow]] = [:]

    /// Read files in slices so a huge transcript never has to fit in memory at once.
    private static let chunkSize = 4 * 1024 * 1024

    public init(historyDays: Int = 30, calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.historyDays = historyDays
        self.calendar = calendar
        self.now = now
    }

    /// Sets the log connections to read, in display order. Connections that are left out are
    /// forgotten; one whose folders or format changed starts over.
    public func configure(_ newSources: [(id: String, source: LogSource)]) {
        let incoming = Dictionary(newSources.map { ($0.id, $0.source) }, uniquingKeysWith: { first, _ in first })
        for (id, source) in sources where incoming[id] != source {
            reset(id)
        }
        sources = incoming
        order = newSources.map(\.id)
    }

    private func reset(_ id: String) {
        cursors = cursors.filter { $0.value.connectionID != id }
        states[id] = nil
    }

    private var cutoff: Date {
        let startOfToday = calendar.startOfDay(for: now())
        return calendar.date(byAdding: .day, value: -(historyDays - 1), to: startOfToday) ?? startOfToday
    }

    // MARK: - Scanning

    /// Reads whatever was appended to the logs since the last call.
    public func scan() {
        let cutoff = self.cutoff
        for id in order {
            guard let source = sources[id] else { continue }
            var count = 0
            var writes: [String: Date] = [:]
            for root in source.roots {
                for (url, size, modified) in Self.jsonlFiles(under: root) {
                    count += 1
                    let key = id + "|" + url.path
                    let cursor: FileCursor
                    if let existing = cursors[key] {
                        cursor = existing
                    } else {
                        // Files untouched since before the history window hold nothing we show.
                        if modified < cutoff { continue }
                        cursor = FileCursor(connectionID: id, format: source.format)
                        cursors[key] = cursor
                    }
                    if source.format == .claude, let session = Self.claudeSessionID(of: url) {
                        writes[session] = max(writes[session] ?? .distantPast, modified)
                    }
                    if size < cursor.offset {
                        // Truncated or replaced: read again; duplicate keys are dropped anyway.
                        cursor.offset = 0
                        cursor.remainder = Data()
                        if source.format == .codex { cursor.codex = CodexLogParser() }
                    }
                    if size > cursor.offset {
                        read(url, cursor: cursor)
                    }
                }
            }
            states[id, default: ConnectionState()].fileCount = count
            states[id, default: ConnectionState()].transcriptWrites = writes
        }
    }

    private func read(_ url: URL, cursor: FileCursor) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: cursor.offset)
            while let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                cursor.offset += UInt64(chunk.count)
                cursor.remainder.append(chunk)
                consumeLines(cursor)
            }
        } catch {
            return
        }
    }

    /// Hands every complete line to the parser and keeps a partially written last line for later.
    private func consumeLines(_ cursor: FileCursor) {
        let newline = UInt8(ascii: "\n")
        guard let lastNewline = cursor.remainder.lastIndex(of: newline) else { return }
        let complete = cursor.remainder[cursor.remainder.startIndex..<lastNewline]
        cursor.remainder = Data(cursor.remainder[cursor.remainder.index(after: lastNewline)...])

        for slice in complete.split(separator: newline, omittingEmptySubsequences: true) {
            guard let line = String(data: Data(slice), encoding: .utf8) else { continue }
            handle(line, cursor: cursor)
        }
    }

    private func handle(_ line: String, cursor: FileCursor) {
        let id = cursor.connectionID
        switch cursor.format {
        case .claude:
            if let event = ClaudeLogParser.parse(line) { ingest(event, into: id) }
        case .codex:
            guard let parser = cursor.codex else { return }
            if let event = parser.parse(line) { ingest(event, into: id) }
            var state = states[id, default: ConnectionState()]
            if let p = parser.primary, p.observedAt >= (state.codexPrimary?.observedAt ?? .distantPast) { state.codexPrimary = p }
            if let s = parser.secondary, s.observedAt >= (state.codexSecondary?.observedAt ?? .distantPast) { state.codexSecondary = s }
            states[id] = state
        }
    }

    /// Adds one event to a connection unless it is older than the history window or was already counted.
    public func ingest(_ event: UsageEvent, into id: String) {
        guard event.timestamp >= cutoff else { return }
        var state = states[id, default: ConnectionState()]
        guard state.seenKeys.insert(event.key).inserted else {
            states[id] = state
            return
        }

        let key = dayKey(event.timestamp)
        var day = state.days[key] ?? DayAggregate()
        day.tokens += event.tokens
        day.requests += 1
        if let session = event.sessionID {
            day.sessions.insert(session)
            var usage = day.sessionUsage[session] ?? SessionAggregate()
            usage.tokens += event.tokens
            usage.requests += 1
            if event.project != nil { usage.project = event.project }
            if event.timestamp >= usage.latest {
                usage.latest = event.timestamp
                usage.model = event.model
            }
            day.sessionUsage[session] = usage
        }
        day.modelTokens[event.model, default: .zero] += event.tokens
        state.days[key] = day

        if event.timestamp > now().addingTimeInterval(-24 * 3_600) {
            state.recent.append(RecentEvent(timestamp: event.timestamp, tokens: event.tokens))
        }
        if event.timestamp > state.lastActivity ?? .distantPast {
            state.lastActivity = event.timestamp
        }
        states[id] = state
    }

    // MARK: - Snapshot

    /// One snapshot per configured log connection, in configuration order. Names and kinds are
    /// placeholders; the caller fills them in from its connection list.
    public func snapshot() -> [ToolSnapshot] {
        let now = self.now()
        let startOfToday = calendar.startOfDay(for: now)
        return order.compactMap { id -> ToolSnapshot? in
            guard let source = sources[id] else { return nil }
            var state = states[id] ?? ConnectionState()
            state.recent.removeAll { $0.timestamp < now.addingTimeInterval(-24 * 3_600) }
            states[id] = state

            let daily: [DailyPoint] = (0..<historyDays).reversed().map { offset in
                let date = calendar.date(byAdding: .day, value: -offset, to: startOfToday) ?? startOfToday
                let day = state.days[dayKey(date)]
                return DailyPoint(date: date, tokens: day?.tokens ?? .zero)
            }
            let today = state.days[dayKey(now)] ?? DayAggregate()
            let week = daily.suffix(7)
            let last5h = state.recent.filter { $0.timestamp >= now.addingTimeInterval(-5 * 3_600) }

            var snapshot = ToolSnapshot(id: id, kind: source.format == .claude ? .claude : .codex, name: "")
            snapshot.logFileCount = state.fileCount
            snapshot.hasData = state.fileCount > 0
            snapshot.today = today.tokens
            snapshot.todaySessions = today.sessions.count
            snapshot.todayRequests = today.requests
            snapshot.topModel = today.modelTokens.max { $0.value.total < $1.value.total }?.key
            snapshot.models = modelUsage(today: today, startOfToday: startOfToday, state: state)
            if source.format == .claude { snapshot.sessions = sessions(today: today, state: state) }
            snapshot.last5Hours = last5h.reduce(.zero) { $0 + $1.tokens }
            snapshot.week = week.reduce(.zero) { $0 + $1.tokens }
            snapshot.month = daily.reduce(.zero) { $0 + $1.tokens }
            snapshot.daily = daily
            snapshot.lastActivity = state.lastActivity
            snapshot.planWindows = planWindows(for: id, state: state, format: source.format, now: now)
            return snapshot
        }
    }

    /// Tokens per model for today and the last 7 days (today included), most used this week first.
    private func modelUsage(today: DayAggregate, startOfToday: Date, state: ConnectionState) -> [ModelUsage] {
        var week: [String: TokenCounts] = [:]
        for offset in 0..<min(7, historyDays) {
            let date = calendar.date(byAdding: .day, value: -offset, to: startOfToday) ?? startOfToday
            for (model, tokens) in state.days[dayKey(date)]?.modelTokens ?? [:] { week[model, default: .zero] += tokens }
        }
        return week
            .map { ModelUsage(model: $0.key, today: today.modelTokens[$0.key] ?? .zero, week: $0.value) }
            .sorted { ($0.week.total, $1.model) > ($1.week.total, $0.model) }
    }

    private func sessions(today: DayAggregate, state: ConnectionState) -> [SessionUsage] {
        today.sessionUsage
            .map { id, usage in
                SessionUsage(id: id, project: usage.project, model: usage.model, today: usage.tokens, requests: usage.requests,
                             lastActivity: max(usage.latest, state.transcriptWrites[id] ?? .distantPast))
            }
            .sorted { ($0.lastActivity, $1.id) > ($1.lastActivity, $0.id) }
    }

    /// Windows that have already reset are dropped: their old percentage no longer holds.
    private func planWindows(for id: String, state: ConnectionState, format: LogFormat, now: Date) -> [PlanWindow] {
        let windows: [PlanWindow]
        switch format {
        case .claude: windows = externalPlanWindows[id] ?? []
        case .codex: windows = [state.codexPrimary?.window, state.codexSecondary?.window].compactMap { $0 }
        }
        return windows.filter { ($0.resetsAt ?? .distantFuture) > now }
    }

    private func dayKey(_ date: Date) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    // MARK: - Files

    /// `<project>/<session>.jsonl`, or `<project>/<session>/subagents/agent-*.jsonl` for its helpers.
    static func claudeSessionID(of url: URL) -> String? {
        let parts = url.pathComponents
        if let index = parts.lastIndex(of: "subagents"), index > 0 { return parts[index - 1] }
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? nil : name
    }

    static func jsonlFiles(under root: URL) -> [(url: URL, size: UInt64, modified: Date)] {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [(url: URL, size: UInt64, modified: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            // Refuse symlink escape: the resolved file must stay under the resolved root.
            guard LogPath.isUnderRoot(url, root: resolvedRoot) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append((url: url, size: UInt64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast))
        }
        return files
    }
}

import Foundation

/// Scans log folders incrementally and keeps per-day totals in memory, separately for every
/// log-based connection (there can be any number of them).
///
/// Not thread-safe: call every method from the same serial queue.
///
/// When `checkpointURL` is set, cursors and day aggregates persist across process restarts so
/// cold starts and `brim status` do not re-parse completed files.
public final class UsageEngine: @unchecked Sendable {
    /// Read position and parser state of one log file within one connection.
    private final class FileCursor {
        let connectionID: String
        let format: LogFormat
        var offset: UInt64 = 0
        var remainder = Data()
        var codex: CodexLogParser?
        /// Last observed size/mtime (whole seconds); when `offset == size` and both match, the file is skipped.
        var knownSize: UInt64 = 0
        var knownModifiedSeconds: Int64 = .min

        init(connectionID: String, format: LogFormat) {
            self.connectionID = connectionID
            self.format = format
            if format == .codex { codex = CodexLogParser() }
        }

        static func seconds(of date: Date) -> Int64 {
            Int64(date.timeIntervalSince1970.rounded(.down))
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
        /// Flat set for O(1) de-dup; kept in sync with `seenKeysByDay` for pruning.
        var seenKeys = Set<String>()
        var seenKeysByDay: [Int: Set<String>] = [:]
        var days: [Int: DayAggregate] = [:]
        var recent: [RecentEvent] = []
        var lastActivity: Date?
        /// When each session's transcript was last written, which also covers tool runs and prompts.
        var transcriptWrites: [String: Date] = [:]
        var codexPrimary: (window: PlanWindow, observedAt: Date)?
        var codexSecondary: (window: PlanWindow, observedAt: Date)?
    }

    public private(set) var historyDays: Int
    public let checkpointURL: URL?
    private let calendar: Calendar
    private let now: () -> Date

    private var sources: [String: LogSource] = [:]
    private var order: [String] = []
    private var cursors: [String: FileCursor] = [:]
    private var states: [String: ConnectionState] = [:]
    private var checkpointLoaded = false
    /// Widest window already reflected in cursors/aggregates (from scans or a loaded checkpoint).
    private var widestScannedDays = 0

    /// Plan windows reported outside the logs (Claude's status line), per connection ID.
    public var externalPlanWindows: [String: [PlanWindow]] = [:]

    /// Read files in slices so a huge transcript never has to fit in memory at once.
    private static let chunkSize = 4 * 1024 * 1024

    /// Compact island / fast CLI default: today only.
    public static let compactHistoryDays = 1
    /// Default `brim status` window (week totals without a full 30d parse).
    public static let cliHistoryDays = 7
    /// Expanded island and `brim status --full`.
    public static let fullHistoryDays = 30

    public init(
        historyDays: Int = UsageEngine.fullHistoryDays,
        checkpointURL: URL? = nil,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.historyDays = max(1, historyDays)
        self.checkpointURL = checkpointURL
        self.calendar = calendar
        self.now = now
    }

    /// Sets the log connections to read, in display order. Connections that are left out are
    /// forgotten; one whose folders or format changed starts over.
    public func configure(_ newSources: [(id: String, source: LogSource)]) {
        loadCheckpointIfNeeded()
        let incoming = Dictionary(newSources.map { ($0.id, $0.source) }, uniquingKeysWith: { first, _ in first })
        for (id, source) in sources where incoming[id] != source {
            reset(id)
        }
        sources = incoming
        order = newSources.map(\.id)
        // Drop checkpoint state for connections that are no longer configured.
        for id in states.keys where incoming[id] == nil {
            reset(id)
        }
    }

    /// Widens or narrows the history window. Expanding past what has already been scanned
    /// re-reads files (seenKeys prevent double counts); narrowing only changes the snapshot length.
    public func setHistoryDays(_ days: Int) {
        let next = max(1, days)
        guard next != historyDays else { return }
        let needsRescan = next > widestScannedDays
        historyDays = next
        if needsRescan {
            // Older events were skipped; re-read from the start. Dedup keeps totals stable.
            for (_, cursor) in cursors {
                cursor.offset = 0
                cursor.remainder = Data()
                cursor.knownSize = 0
                cursor.knownModifiedSeconds = .min
                if cursor.format == .codex { cursor.codex = CodexLogParser() }
            }
        }
        prune()
    }

    private func reset(_ id: String) {
        cursors = cursors.filter { $0.value.connectionID != id }
        states[id] = nil
    }

    /// Cutoff for ingesting new events and for opening files that have no cursor yet.
    private var cutoff: Date {
        startOfDay(offset: -(historyDays - 1))
    }

    /// Days kept in memory and on disk so compact scans do not erase a wider shared checkpoint.
    private var retentionCutoff: Date {
        startOfDay(offset: -(Self.fullHistoryDays - 1))
    }

    private func startOfDay(offset: Int) -> Date {
        let startOfToday = calendar.startOfDay(for: now())
        return calendar.date(byAdding: .day, value: offset, to: startOfToday) ?? startOfToday
    }

    // MARK: - Scanning

    /// Reads whatever was appended to the logs since the last call (or since the checkpoint).
    public func scan() {
        loadCheckpointIfNeeded()
        let cutoff = self.cutoff
        var truncated = Set<String>()
        for id in order {
            guard let source = sources[id] else { continue }
            for root in source.roots {
                for (url, size, modified) in Self.jsonlFiles(under: root) {
                    let key = id + "|" + url.path
                    guard let cursor = cursors[key] else { continue }
                    let modifiedSeconds = FileCursor.seconds(of: modified)
                    if size < cursor.offset {
                        truncated.insert(id)
                    } else if cursor.offset > 0,
                              cursor.offset == cursor.knownSize,
                              cursor.remainder.isEmpty,
                              (size != cursor.knownSize || modifiedSeconds != cursor.knownModifiedSeconds),
                              size <= cursor.knownSize {
                        // Completed file was replaced in place (same or shorter length).
                        truncated.insert(id)
                    }
                }
            }
        }
        for id in truncated {
            invalidateAggregates(id)
        }

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
                    let modifiedSeconds = FileCursor.seconds(of: modified)
                    if size < cursor.offset || truncated.contains(id) {
                        cursor.offset = 0
                        cursor.remainder = Data()
                        cursor.knownSize = 0
                        cursor.knownModifiedSeconds = .min
                        if source.format == .codex { cursor.codex = CodexLogParser() }
                    }
                    // Completed and unchanged: skip open once cursors persist across restarts.
                    if size == cursor.offset,
                       size == cursor.knownSize,
                       modifiedSeconds == cursor.knownModifiedSeconds,
                       cursor.remainder.isEmpty {
                        continue
                    }
                    if size > cursor.offset || !cursor.remainder.isEmpty || truncated.contains(id) {
                        if cursor.offset == 0 { cursor.remainder = Data() }
                        read(url, cursor: cursor)
                    }
                    cursor.knownSize = size
                    cursor.knownModifiedSeconds = modifiedSeconds
                }
            }
            states[id, default: ConnectionState()].fileCount = count
            states[id, default: ConnectionState()].transcriptWrites = writes
        }
        widestScannedDays = max(widestScannedDays, historyDays)
        prune()
        saveCheckpoint()
    }

    /// Clears day aggregates and seenKeys for a connection after a truncated/replaced log file.
    private func invalidateAggregates(_ id: String) {
        states[id] = ConnectionState()
        for (_, cursor) in cursors where cursor.connectionID == id {
            cursor.offset = 0
            cursor.remainder = Data()
            cursor.knownSize = 0
            cursor.knownModifiedSeconds = .min
            if cursor.format == .codex { cursor.codex = CodexLogParser() }
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
        state.seenKeysByDay[key, default: []].insert(event.key)

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

    // MARK: - Pruning

    /// Drops days older than the 30-day retention window, their seenKeys, and past-day session
    /// maps so RSS stays bounded without erasing a shared checkpoint when scanning compact (1d).
    public func prune() {
        let retentionKey = dayKey(retentionCutoff)
        let todayKey = dayKey(now())
        for id in states.keys {
            var state = states[id] ?? ConnectionState()
            let staleDays = state.days.keys.filter { $0 < retentionKey }
            for day in staleDays {
                if let keys = state.seenKeysByDay.removeValue(forKey: day) {
                    for key in keys { state.seenKeys.remove(key) }
                }
                state.days.removeValue(forKey: day)
            }
            for day in state.seenKeysByDay.keys.filter({ $0 < retentionKey }) {
                if let keys = state.seenKeysByDay.removeValue(forKey: day) {
                    for key in keys { state.seenKeys.remove(key) }
                }
            }
            // Past days keep token/model totals only — session detail is for today.
            for dayKey in state.days.keys where dayKey != todayKey {
                state.days[dayKey]?.sessionUsage.removeAll(keepingCapacity: false)
            }
            state.recent.removeAll { $0.timestamp < now().addingTimeInterval(-24 * 3_600) }
            states[id] = state
        }
        if !sources.isEmpty {
            cursors = cursors.filter { sources[$0.value.connectionID] != nil }
        }
    }

    // MARK: - Snapshot

    /// One snapshot per configured log connection, in configuration order. Names and kinds are
    /// placeholders; the caller fills them in from its connection list.
    public func snapshot() -> [ToolSnapshot] {
        let now = self.now()
        let startOfToday = calendar.startOfDay(for: now)
        prune()
        return order.compactMap { id -> ToolSnapshot? in
            guard let source = sources[id] else { return nil }
            let state = states[id] ?? ConnectionState()

            let daily: [DailyPoint] = (0..<historyDays).reversed().map { offset in
                let date = calendar.date(byAdding: .day, value: -offset, to: startOfToday) ?? startOfToday
                let day = state.days[dayKey(date)]
                return DailyPoint(date: date, tokens: day?.tokens ?? .zero)
            }
            let today = state.days[dayKey(now)] ?? DayAggregate()
            let week = daily.suffix(min(7, historyDays))
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

    private func dayKeyString(_ key: Int) -> String { String(key) }

    private func parseDayKey(_ text: String) -> Int? { Int(text) }

    // MARK: - Checkpoint

    private func loadCheckpointIfNeeded() {
        guard !checkpointLoaded else { return }
        checkpointLoaded = true
        guard let url = checkpointURL, let checkpoint = UsageCheckpoint.load(from: url) else { return }
        widestScannedDays = max(widestScannedDays, checkpoint.historyDays)
        apply(checkpoint)
    }

    /// Restores cursors and aggregates from disk. Codex file offsets are reset to 0 (parser state
    /// is not persisted); Claude offsets stay incremental. `seenKeys` prevent double counts.
    private func apply(_ checkpoint: UsageCheckpoint) {
        let todayKey = dayKey(now())
        for (id, stored) in checkpoint.connections {
            var state = ConnectionState()
            state.lastActivity = stored.lastActivity
            state.transcriptWrites = stored.transcriptWrites
            if let window = stored.codexPrimary, let at = stored.codexPrimaryAt {
                state.codexPrimary = (window, at)
            }
            if let window = stored.codexSecondary, let at = stored.codexSecondaryAt {
                state.codexSecondary = (window, at)
            }
            for (dayText, keys) in stored.seenKeysByDay {
                guard let day = parseDayKey(dayText) else { continue }
                let set = Set(keys)
                state.seenKeysByDay[day] = set
                state.seenKeys.formUnion(set)
            }
            for (dayText, dayStored) in stored.days {
                guard let day = parseDayKey(dayText) else { continue }
                var aggregate = DayAggregate()
                aggregate.tokens = dayStored.tokens
                aggregate.requests = dayStored.requests
                aggregate.sessions = Set(dayStored.sessions)
                aggregate.modelTokens = dayStored.modelTokens
                if day == todayKey, let sessions = dayStored.sessionUsage {
                    for (sessionID, session) in sessions {
                        aggregate.sessionUsage[sessionID] = SessionAggregate(
                            project: session.project,
                            model: session.model,
                            latest: session.latest,
                            tokens: session.tokens,
                            requests: session.requests
                        )
                    }
                }
                state.days[day] = aggregate
            }
            states[id] = state

            for (path, file) in stored.files {
                let key = id + "|" + path
                let cursor = FileCursor(connectionID: id, format: file.format)
                if file.format == .claude {
                    // Persist incomplete-line safety: offset is the last fully consumed byte.
                    cursor.offset = file.offset
                    cursor.knownSize = file.size
                    cursor.knownModifiedSeconds = file.modifiedSeconds
                } else {
                    // Codex parser state is not on disk; re-scan and rely on seenKeys.
                    cursor.offset = 0
                    cursor.knownSize = 0
                    cursor.knownModifiedSeconds = .min
                }
                cursors[key] = cursor
            }
        }
        prune()
    }

    public func saveCheckpoint() {
        guard let url = checkpointURL else { return }
        let todayKey = dayKey(now())
        let retentionKey = dayKey(retentionCutoff)
        // Merge with any wider history already on disk so a compact (1d) scan does not wipe it.
        var connections = UsageCheckpoint.load(from: url)?.connections ?? [:]
        for id in order {
            guard let state = states[id] else { continue }
            var files: [String: FileCheckpoint] = [:]
            let prefix = id + "|"
            for (key, cursor) in cursors where key.hasPrefix(prefix) {
                let path = String(key.dropFirst(prefix.count))
                // Store offset past any incomplete trailing line so restore does not skip it.
                let committed = cursor.offset > UInt64(cursor.remainder.count)
                    ? cursor.offset - UInt64(cursor.remainder.count)
                    : 0
                files[path] = FileCheckpoint(
                    offset: committed,
                    size: cursor.knownSize,
                    modifiedSeconds: cursor.knownModifiedSeconds == .min ? 0 : cursor.knownModifiedSeconds,
                    format: cursor.format
                )
            }
            var seenKeysByDay = connections[id]?.seenKeysByDay ?? [:]
            for (day, keys) in state.seenKeysByDay {
                seenKeysByDay[dayKeyString(day)] = keys.sorted()
            }
            seenKeysByDay = seenKeysByDay.filter { parseDayKey($0.key).map { $0 >= retentionKey } ?? false }

            var days = connections[id]?.days ?? [:]
            for (day, aggregate) in state.days {
                var sessionUsage: [String: SessionCheckpoint]?
                if day == todayKey {
                    sessionUsage = Dictionary(uniqueKeysWithValues: aggregate.sessionUsage.map { id, usage in
                        (id, SessionCheckpoint(project: usage.project, model: usage.model,
                                               latest: usage.latest, tokens: usage.tokens, requests: usage.requests))
                    })
                }
                days[dayKeyString(day)] = DayCheckpoint(
                    tokens: aggregate.tokens,
                    requests: aggregate.requests,
                    sessions: aggregate.sessions.sorted(),
                    modelTokens: aggregate.modelTokens,
                    sessionUsage: sessionUsage
                )
            }
            days = days.filter { parseDayKey($0.key).map { $0 >= retentionKey } ?? false }

            connections[id] = ConnectionCheckpoint(
                files: files,
                seenKeysByDay: seenKeysByDay,
                days: days,
                lastActivity: state.lastActivity ?? connections[id]?.lastActivity,
                transcriptWrites: state.transcriptWrites.isEmpty ? (connections[id]?.transcriptWrites ?? [:]) : state.transcriptWrites,
                codexPrimary: state.codexPrimary?.window ?? connections[id]?.codexPrimary,
                codexPrimaryAt: state.codexPrimary?.observedAt ?? connections[id]?.codexPrimaryAt,
                codexSecondary: state.codexSecondary?.window ?? connections[id]?.codexSecondary,
                codexSecondaryAt: state.codexSecondary?.observedAt ?? connections[id]?.codexSecondaryAt
            )
        }
        // Drop connections no longer configured once we know the active set.
        if !order.isEmpty {
            connections = connections.filter { order.contains($0.key) }
        }
        UsageCheckpoint(
            savedAt: now(),
            historyDays: max(historyDays, widestScannedDays),
            connections: connections
        ).save(to: url)
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

    // MARK: - Test hooks

    /// Number of retained seenKeys across all connections (for prune tests).
    public var retainedSeenKeyCount: Int {
        states.values.reduce(0) { $0 + $1.seenKeys.count }
    }

    /// Whether any past-day sessionUsage maps still hold entries (should be empty after prune).
    public var pastDaySessionUsageCount: Int {
        let today = dayKey(now())
        return states.values.reduce(0) { total, state in
            total + state.days.reduce(0) { partial, entry in
                entry.key == today ? partial : partial + entry.value.sessionUsage.count
            }
        }
    }
}

import Foundation

/// A small Codable value kept as JSON in Brim's support folder (notes, links, timers…).
public struct JSONFile<Value: Codable> {
    public let url: URL

    public init(_ name: String, directory: URL = JSONFile.supportDirectory) {
        url = directory.appendingPathComponent(name)
    }

    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Brim", isDirectory: true)
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    public func save(_ value: Value) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Notes

public struct Note: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var updated: Date
    /// Pinned notes stay at the top of the list. Optional so older notes files still load.
    public var pinned: Bool?

    public init(id: String = UUID().uuidString, title: String = "", body: String = "", updated: Date = Date(), pinned: Bool = false) {
        self.id = id
        self.title = title
        self.body = body
        self.updated = updated
        self.pinned = pinned ? true : nil
    }

    public var isPinned: Bool { pinned ?? false }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// The first line of the body, for the list.
    public var snippet: String {
        body.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "No text"
    }

    public var wordCount: Int {
        body.split { $0.isWhitespace || $0.isNewline }.count
    }

    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(q) || body.localizedCaseInsensitiveContains(q)
    }
}

// MARK: - Links

public struct SavedLink: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var url: String
    public var folder: String

    public init(id: String = UUID().uuidString, title: String, url: String, folder: String) {
        self.id = id
        self.title = title
        self.url = url
        self.folder = folder
    }

    /// "github.com" from "https://www.github.com/brim".
    public var host: String {
        guard let host = URL(string: Links.normalized(url))?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(q) || url.localizedCaseInsensitiveContains(q)
    }
}

public enum Links {
    public static let defaultFolders = ["Work", "Reading", "Tools"]

    /// Adds https:// when the user typed a bare domain.
    public static func normalized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") { return trimmed }
        return "https://" + trimmed
    }

    /// Whether typed text looks like an address rather than a search.
    public static func looksLikeURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return false }
        if trimmed.contains("://") { return true }
        let parts = trimmed.split(separator: "/").first?.split(separator: ".") ?? []
        return parts.count >= 2 && (parts.last?.count ?? 0) >= 2 && parts.last?.allSatisfy(\.isLetter) == true
    }

    public static func searchURL(_ query: String) -> URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    /// A title from a URL when the user didn't give one: "github.com/brim" → "Github".
    public static func suggestedTitle(for url: String) -> String {
        let host = SavedLink(title: "", url: url, folder: "").host
        let name = host.split(separator: ".").dropLast().last.map(String.init) ?? host
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

// MARK: - Timers

/// Pomodoro, countdown and stopwatch state as plain values; the app ticks them once a second.
public struct TimerState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case focus, shortBreak, longBreak

        public var title: String {
            switch self {
            case .focus: return "Focus"
            case .shortBreak: return "Short break"
            case .longBreak: return "Long break"
            }
        }
    }

    public var focusMinutes = 25
    public var shortBreakMinutes = 5
    public var longBreakMinutes = 15
    public var sessionsPerSet = 4

    public var phase: Phase = .focus
    /// When the running pomodoro ends; nil while paused.
    public var pomodoroEnds: Date?
    /// Seconds left while paused.
    public var pomodoroLeft: TimeInterval = 25 * 60
    public var sessionsToday = 0
    public var sessionsDay = ""

    public var countdownTotal: TimeInterval = 10 * 60
    public var countdownEnds: Date?
    public var countdownLeft: TimeInterval = 10 * 60

    public var stopwatchStarted: Date?
    public var stopwatchAccumulated: TimeInterval = 0
    public var laps: [TimeInterval] = []

    public var glasses = 0
    public var glassesDay = ""
    public var glassGoal = 8
    public var remindEveryMinutes = 45
    /// Glasses logged on the calendar day before `glassesDay`, when that day rolled into today.
    /// Nil when there is no trustworthy prior day (first launch or a multi-day gap).
    public var yesterdayGlasses: Int?
    /// Goal that applied on that prior day (kept so a later goal edit does not rewrite the notice).
    public var yesterdayGoal: Int?

    public init() {}

    public func phaseLength(_ phase: Phase) -> TimeInterval {
        switch phase {
        case .focus: return TimeInterval(focusMinutes * 60)
        case .shortBreak: return TimeInterval(shortBreakMinutes * 60)
        case .longBreak: return TimeInterval(longBreakMinutes * 60)
        }
    }

    // Pomodoro

    public var pomodoroRunning: Bool { pomodoroEnds != nil }

    public func pomodoroRemaining(at now: Date = Date()) -> TimeInterval {
        guard let ends = pomodoroEnds else { return pomodoroLeft }
        return max(0, ends.timeIntervalSince(now))
    }

    public mutating func togglePomodoro(at now: Date = Date()) {
        if let ends = pomodoroEnds {
            pomodoroLeft = max(0, ends.timeIntervalSince(now))
            pomodoroEnds = nil
        } else {
            pomodoroEnds = now.addingTimeInterval(pomodoroLeft)
        }
    }

    public mutating func resetPomodoro() {
        pomodoroEnds = nil
        pomodoroLeft = phaseLength(phase)
    }

    /// Ends the current phase and moves to the next. Returns the phase that finished.
    @discardableResult
    public mutating func advancePomodoro(at now: Date = Date(), calendar: Calendar = .current) -> Phase {
        let finished = phase
        rollDay(at: now, calendar: calendar)
        if phase == .focus {
            sessionsToday += 1
            phase = sessionsToday % max(sessionsPerSet, 1) == 0 ? .longBreak : .shortBreak
        } else {
            phase = .focus
        }
        pomodoroEnds = nil
        pomodoroLeft = phaseLength(phase)
        return finished
    }

    // Countdown

    public var countdownRunning: Bool { countdownEnds != nil }

    public func countdownRemaining(at now: Date = Date()) -> TimeInterval {
        guard let ends = countdownEnds else { return countdownLeft }
        return max(0, ends.timeIntervalSince(now))
    }

    public mutating func setCountdown(minutes: Int) {
        countdownTotal = TimeInterval(max(1, minutes) * 60)
        countdownLeft = countdownTotal
        countdownEnds = nil
    }

    public mutating func toggleCountdown(at now: Date = Date()) {
        if let ends = countdownEnds {
            countdownLeft = max(0, ends.timeIntervalSince(now))
            countdownEnds = nil
        } else {
            if countdownLeft <= 0 { countdownLeft = countdownTotal }
            countdownEnds = now.addingTimeInterval(countdownLeft)
        }
    }

    public mutating func resetCountdown() {
        countdownEnds = nil
        countdownLeft = countdownTotal
    }

    // Stopwatch

    public var stopwatchRunning: Bool { stopwatchStarted != nil }

    public func stopwatchElapsed(at now: Date = Date()) -> TimeInterval {
        stopwatchAccumulated + (stopwatchStarted.map { now.timeIntervalSince($0) } ?? 0)
    }

    public mutating func toggleStopwatch(at now: Date = Date()) {
        if let started = stopwatchStarted {
            stopwatchAccumulated += now.timeIntervalSince(started)
            stopwatchStarted = nil
        } else {
            stopwatchStarted = now
        }
    }

    public mutating func lap(at now: Date = Date()) {
        guard stopwatchRunning else { return }
        laps.insert(stopwatchElapsed(at: now), at: 0)
        if laps.count > 20 { laps.removeLast() }
    }

    public mutating func resetStopwatch() {
        stopwatchStarted = nil
        stopwatchAccumulated = 0
        laps = []
    }

    // Hydration

    /// Hard cap: one overflow row (goal × 2), never more.
    public var maxGlasses: Int { max(glassGoal, 1) * 2 }

    /// 2 when today's count is past the goal; otherwise 1. Never more than two rows.
    public var hydrationRowCount: Int { glasses > glassGoal ? 2 : 1 }

    /// How many glasses in `row` (0 = goal row, 1 = overflow) are filled.
    public func filledGlasses(inRow row: Int) -> Int {
        switch row {
        case 0: return min(max(glasses, 0), max(glassGoal, 0))
        case 1: return max(0, min(glasses - glassGoal, glassGoal))
        default: return 0
        }
    }

    /// True when yesterday existed and finished under goal. Prefer this over a "completed" banner.
    public var yesterdayMissedGoal: Bool {
        guard let prior = yesterdayGlasses, let goal = yesterdayGoal else { return false }
        return prior < goal
    }

    /// e.g. "Yesterday: 5/8 — goal not met". Nil when met or unknown.
    public var yesterdayIncompleteMessage: String? {
        guard yesterdayMissedGoal, let prior = yesterdayGlasses, let goal = yesterdayGoal else { return nil }
        return "Yesterday: \(prior)/\(goal) — goal not met"
    }

    public mutating func addGlass(_ delta: Int, at now: Date = Date(), calendar: Calendar = .current) {
        rollDay(at: now, calendar: calendar)
        glasses = max(0, min(maxGlasses, glasses + delta))
    }

    /// True when local day keys for sessions or glasses are stale relative to `now`.
    public func needsDayRoll(at now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let day = QuotaHistory.key(for: now, calendar: calendar)
        return glassesDay != day || sessionsDay != day
    }

    /// Daily counters start again after midnight. Persists yesterday's count before clearing today.
    public mutating func rollDay(at now: Date = Date(), calendar: Calendar = .current) {
        let day = QuotaHistory.key(for: now, calendar: calendar)
        if sessionsDay != day { sessionsDay = day; sessionsToday = 0 }
        guard glassesDay != day else { return }
        if glassesDay.isEmpty {
            yesterdayGlasses = nil
            yesterdayGoal = nil
        } else if let priorDate = calendar.date(byAdding: .day, value: -1, to: now),
                  glassesDay == QuotaHistory.key(for: priorDate, calendar: calendar) {
            yesterdayGlasses = glasses
            yesterdayGoal = glassGoal
        } else {
            // Multi-day gap: do not pretend the last logged day was "yesterday".
            yesterdayGlasses = nil
            yesterdayGoal = nil
        }
        glassesDay = day
        glasses = 0
    }
}

public enum Clock {
    /// "24:59" or "1:02:03".
    public static func mmss(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// Stopwatch style with tenths: "03:07.4".
    public static func tenths(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let whole = Int(total)
        return String(format: "%02d:%02d.%d", whole / 60, whole % 60, Int((total - Double(whole)) * 10))
    }

    /// "5h 48m" or "32m".
    public static func hm(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

// MARK: - Web search

/// A search engine: a URL template with `%s` where the words go, and a short keyword.
public struct SearchEngine: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var template: String
    /// Typing "yt cats" searches YouTube for "cats".
    public var keyword: String
    public var builtIn: Bool

    public init(id: String = UUID().uuidString, name: String, template: String, keyword: String, builtIn: Bool = false) {
        self.id = id
        self.name = name
        self.template = template
        self.keyword = keyword.lowercased()
        self.builtIn = builtIn
    }

    /// The search URL for these words, or nil if the template isn't a valid URL.
    public func url(for terms: String) -> URL? {
        let encoded = terms.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? terms
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    /// A template is usable when it's an http(s) URL with a `%s`.
    public static func isValid(_ template: String) -> Bool {
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("%s"), let url = URL(string: trimmed.replacingOccurrences(of: "%s", with: "x")),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else { return false }
        return true
    }
}

public enum SearchEngines {
    public static let builtIn: [SearchEngine] = [
        SearchEngine(id: "google", name: "Google", template: "https://www.google.com/search?q=%s", keyword: "g", builtIn: true),
        SearchEngine(id: "duckduckgo", name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s", keyword: "d", builtIn: true),
        SearchEngine(id: "perplexity", name: "Perplexity", template: "https://www.perplexity.ai/search?q=%s", keyword: "p", builtIn: true),
        SearchEngine(id: "chatgpt", name: "ChatGPT", template: "https://chatgpt.com/?q=%s", keyword: "c", builtIn: true),
        SearchEngine(id: "claude", name: "Claude", template: "https://claude.ai/new?q=%s", keyword: "cl", builtIn: true),
        SearchEngine(id: "youtube", name: "YouTube", template: "https://www.youtube.com/results?search_query=%s", keyword: "yt", builtIn: true),
        SearchEngine(id: "github", name: "GitHub", template: "https://github.com/search?q=%s", keyword: "gh", builtIn: true),
        SearchEngine(id: "brave", name: "Brave", template: "https://search.brave.com/search?q=%s", keyword: "b", builtIn: true),
        SearchEngine(id: "kagi", name: "Kagi", template: "https://kagi.com/search?q=%s", keyword: "k", builtIn: true),
        SearchEngine(id: "wikipedia", name: "Wikipedia", template: "https://en.wikipedia.org/w/index.php?search=%s", keyword: "w", builtIn: true),
    ]

    /// Splits "yt lofi beats" into YouTube + "lofi beats". A leading "!" works too ("!gh brim").
    /// Without a known keyword the whole text goes to `fallback`.
    public static func resolve(_ text: String, engines: [SearchEngine], fallback: SearchEngine) -> (engine: SearchEngine, terms: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else { return (fallback, trimmed) }
        var word = String(trimmed[..<space]).lowercased()
        if word.hasPrefix("!") { word.removeFirst() }
        let rest = trimmed[space...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, let engine = engines.first(where: { $0.keyword == word }) else { return (fallback, trimmed) }
        return (engine, rest)
    }
}

extension CharacterSet {
    /// Characters left as they are inside a query value (so "&", "=", "+" and "#" get encoded).
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+#?")
        return set
    }()
}

// MARK: - Clipboard

/// What a copied piece of text looks like, for the Clipboard preview.
public enum ClipText {
    /// "#1E90FF", "#fff" or "1e90ff" → RGB in 0–1.
    public static func hexColor(_ text: String) -> (red: Double, green: Double, blue: Double)? {
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard [3, 6].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
        // Bare six-digit words like "decade" or "000000" only count with a #.
        if !text.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
           hex.count != 6 || !hex.contains(where: \.isNumber) || !hex.contains(where: \.isLetter) { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard let value = UInt32(hex, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    public static func isEmail(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" "), !trimmed.contains("\n"), let at = trimmed.firstIndex(of: "@") else { return false }
        let domain = trimmed[trimmed.index(after: at)...]
        return at != trimmed.startIndex && domain.contains(".") && !domain.hasSuffix(".")
    }

    /// "142 characters · 23 words · 3 lines".
    public static func stats(_ text: String) -> String {
        let characters = text.count
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        var parts = ["\(characters) character\(characters == 1 ? "" : "s")", "\(words) word\(words == 1 ? "" : "s")"]
        if lines > 1 { parts.append("\(lines) lines") }
        return parts.joined(separator: " · ")
    }
}

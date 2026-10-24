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
}

// MARK: - Notes

public struct Note: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var updated: Date

    public init(id: String = UUID().uuidString, title: String = "", body: String = "", updated: Date = Date()) {
        self.id = id
        self.title = title
        self.body = body
        self.updated = updated
    }

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

    public mutating func addGlass(_ delta: Int, at now: Date = Date(), calendar: Calendar = .current) {
        rollDay(at: now, calendar: calendar)
        glasses = max(0, min(glassGoal * 2, glasses + delta))
    }

    /// Daily counters start again after midnight.
    public mutating func rollDay(at now: Date = Date(), calendar: Calendar = .current) {
        let day = QuotaHistory.key(for: now, calendar: calendar)
        if sessionsDay != day { sessionsDay = day; sessionsToday = 0 }
        if glassesDay != day { glassesDay = day; glasses = 0 }
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

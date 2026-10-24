import AppKit
import Combine
import IslandCore
import IslandSystem
import UserNotifications

/// Where local tabs keep their files: Brim's support folder, or a scratch folder for snapshots.
enum LocalData {
    static var directory: URL {
        AppSettings.isSnapshot
            ? FileManager.default.temporaryDirectory.appendingPathComponent("brim-snapshot-\(ProcessInfo.processInfo.processIdentifier)")
            : JSONFile<Int>.supportDirectory
    }
}

// MARK: - Notes

@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var notes: [Note]
    private let file = JSONFile<[Note]>("notes.json", directory: LocalData.directory)
    private var saveTask: Task<Void, Never>?

    init() {
        notes = file.load() ?? []
        if AppSettings.isSnapshot, notes.isEmpty { notes = Self.samples }
        sortNotes()
    }

    /// Pinned first, then newest.
    private func sortNotes() {
        notes.sort { ($0.isPinned ? 1 : 0, $0.updated) > ($1.isPinned ? 1 : 0, $1.updated) }
    }

    func togglePin(_ id: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].pinned = notes[index].isPinned ? nil : true
        sortNotes()
        save()
    }

    /// When the open note was last saved, for "Saved 3s ago".
    @Published private(set) var savedAt = Date()

    @discardableResult
    func add() -> Note {
        let note = Note()
        notes.insert(note, at: 0)
        save()
        return note
    }

    func update(_ id: String, title: String? = nil, body: String? = nil) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        if let title { notes[index].title = title }
        if let body { notes[index].body = body }
        notes[index].updated = Date()
        saveSoon()
    }

    func delete(_ id: String) {
        notes.removeAll { $0.id == id }
        save()
    }

    /// Typing saves half a second after the last key.
    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        savedAt = Date()
        guard !AppSettings.isSnapshot else { return }
        file.save(notes)
    }

    static let samples: [Note] = [
        Note(title: "v0.4 checklist", body: "Tabs on top\nSettings: reorder and hide tabs\nLight theme\nClosed notch: timer and now playing"),
        Note(title: "Cursor quota notes", body: "Included usage resets on the billing date, not the 1st.", updated: Date().addingTimeInterval(-86_400)),
        Note(title: "Talk outline", body: "1. Why the notch\n2. Reading limits without API keys\n3. Demo", updated: Date().addingTimeInterval(-86_400 * 3)),
    ]
}

// MARK: - Links

@MainActor
final class LinksStore: ObservableObject {
    struct Saved: Codable {
        var links: [SavedLink]
        var folders: [String]
        /// Engines the user added; built-ins aren't saved.
        var customEngines: [SearchEngine]?
        /// Engine IDs shown as pills, in order.
        var pinnedEngines: [String]?
        var defaultEngine: String?
    }

    @Published private(set) var links: [SavedLink]
    @Published private(set) var folders: [String]
    @Published private(set) var customEngines: [SearchEngine]
    @Published private(set) var pinnedEngines: [String]
    @Published private(set) var defaultEngineID: String
    private let file = JSONFile<Saved>("links.json", directory: LocalData.directory)

    static let standardPins = ["google", "duckduckgo", "perplexity", "chatgpt", "youtube", "github"]

    init() {
        let saved = file.load()
        links = saved?.links ?? []
        folders = saved?.folders ?? Links.defaultFolders
        customEngines = saved?.customEngines ?? []
        pinnedEngines = saved?.pinnedEngines ?? Self.standardPins
        defaultEngineID = saved?.defaultEngine ?? "google"
        if AppSettings.isSnapshot, links.isEmpty { links = Self.samples }
    }

    // MARK: Engines

    var engines: [SearchEngine] { SearchEngines.builtIn + customEngines }

    var defaultEngine: SearchEngine { engines.first { $0.id == defaultEngineID } ?? SearchEngines.builtIn[0] }

    /// Pills in the search card; the default is always among them.
    var pinned: [SearchEngine] {
        var ids = pinnedEngines.filter { id in engines.contains { $0.id == id } }
        if !ids.contains(defaultEngineID) { ids.insert(defaultEngineID, at: 0) }
        return ids.compactMap { id in engines.first { $0.id == id } }
    }

    func setDefault(_ id: String) {
        defaultEngineID = id
        if !pinnedEngines.contains(id) { pinnedEngines.insert(id, at: 0) }
        save()
    }

    func setPinned(_ id: String, _ pinned: Bool) {
        if pinned {
            if !pinnedEngines.contains(id) { pinnedEngines.append(id) }
        } else if id != defaultEngineID {
            pinnedEngines.removeAll { $0 == id }
        }
        save()
    }

    /// Adds a custom engine; returns a problem to show, or nil.
    func addEngine(name: String, keyword: String, template: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        let keyword = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        let template = template.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "Give the engine a name." }
        guard SearchEngine.isValid(template) else { return "Use an https address with %s where the search goes." }
        guard keyword.isEmpty || !engines.contains(where: { $0.keyword == keyword }) else { return "“\(keyword)” is already used by another engine." }
        let engine = SearchEngine(name: name, template: template, keyword: keyword)
        customEngines.append(engine)
        pinnedEngines.append(engine.id)
        save()
        return nil
    }

    func removeEngine(_ id: String) {
        customEngines.removeAll { $0.id == id }
        pinnedEngines.removeAll { $0 == id }
        if defaultEngineID == id { defaultEngineID = "google" }
        save()
    }

    // MARK: Links

    func add(title: String, url: String, folder: String) {
        let clean = Links.normalized(url)
        let name = title.trimmingCharacters(in: .whitespaces).isEmpty ? Links.suggestedTitle(for: clean) : title
        links.append(SavedLink(title: name, url: clean, folder: folder))
        if !folders.contains(folder) { folders.append(folder) }
        save()
    }

    func delete(_ id: String) {
        links.removeAll { $0.id == id }
        save()
    }

    func open(_ link: SavedLink) {
        if let url = URL(string: Links.normalized(link.url)) { NSWorkspace.shared.open(url) }
    }

    private func save() {
        guard !AppSettings.isSnapshot else { return }
        file.save(Saved(links: links, folders: folders, customEngines: customEngines, pinnedEngines: pinnedEngines, defaultEngine: defaultEngineID))
    }

    static let samples: [SavedLink] = [
        SavedLink(title: "Anthropic Console", url: "console.anthropic.com", folder: "Work"),
        SavedLink(title: "Claude Code docs", url: "docs.anthropic.com", folder: "Work"),
        SavedLink(title: "abhargava14/brim", url: "github.com/abhargava14/brim", folder: "Work"),
        SavedLink(title: "Linear", url: "linear.app", folder: "Work"),
        SavedLink(title: "Hacker News", url: "news.ycombinator.com", folder: "Reading"),
        SavedLink(title: "Excalidraw", url: "excalidraw.com", folder: "Tools"),
        SavedLink(title: "regex101", url: "regex101.com", folder: "Tools"),
    ]
}

// MARK: - Scratchpad

@MainActor
final class ScratchStore: ObservableObject {
    @Published var text: String {
        didSet { saveSoon() }
    }
    /// Shown in the closed notch instead of the usual rotation.
    @Published var pinned = UserDefaults.standard.bool(forKey: "scratchPinned") {
        didSet { UserDefaults.standard.set(pinned, forKey: "scratchPinned") }
    }
    @Published private(set) var savedAt = Date()

    /// The first non-empty line, for the closed notch.
    var firstLine: String {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
    }

    var wordCount: Int { text.split { $0.isWhitespace || $0.isNewline }.count }
    private let file = JSONFile<String>("scratchpad.json", directory: LocalData.directory)
    private var saveTask: Task<Void, Never>?

    init() {
        text = file.load() ?? (AppSettings.isSnapshot ? "Call back about the launch date\nAPI key rotation: Friday\nhttps://linear.app/brim/issue/BRIM-42" : "")
    }

    private func saveSoon() {
        guard !AppSettings.isSnapshot else { return }
        saveTask?.cancel()
        let value = text, file = self.file
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            file.save(value)
            self?.savedAt = Date()
        }
    }
}

// MARK: - Timers

/// Ticks running timers, saves their state and announces when one finishes.
@MainActor
final class TimerService: ObservableObject {
    @Published var state: TimerState { didSet { save() } }
    /// Changes every second while something runs, so views redraw.
    @Published private(set) var now = Date()
    /// The phase that just finished, shown by the closed notch for a moment.
    @Published private(set) var finished: String?
    private let file = JSONFile<TimerState>("timers.json", directory: LocalData.directory)
    private var timer: Timer?
    private var lastReminder = Date()
    weak var settings: AppSettings?

    init() {
        state = file.load() ?? TimerState()
        state.rollDay()
        if AppSettings.isSnapshot {
            state.sessionsToday = 2
            state.glasses = 5
            state.laps = [184.4, 121.9, 63.2]
            state.stopwatchAccumulated = 187.4
            state.pomodoroLeft = 1122
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 0.1
    }

    var anyRunning: Bool { state.pomodoroRunning || state.countdownRunning || state.stopwatchRunning }

    private func tick() {
        let date = Date()
        if anyRunning { now = date }
        if state.pomodoroRunning, state.pomodoroRemaining(at: date) <= 0 {
            let phase = state.advancePomodoro(at: date)
            announce(phase == .focus ? "Focus done. Time for a break." : "\(phase.title) over. Back to focus.")
        }
        if state.countdownRunning, state.countdownRemaining(at: date) <= 0 {
            state.resetCountdown()
            announce("Countdown finished.")
        }
        // Hydration reminder while the day's goal isn't met.
        if state.remindEveryMinutes > 0, state.glasses < state.glassGoal,
           date.timeIntervalSince(lastReminder) >= TimeInterval(state.remindEveryMinutes * 60) {
            lastReminder = date
            Notifier.post(title: "Time for some water", body: "\(state.glasses) of \(state.glassGoal) glasses today.")
        }
    }

    private func announce(_ message: String) {
        NSSound(named: "Glass")?.play()
        if settings?.interruptTimerDone ?? true {
            finished = message
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                self?.finished = nil
            }
        }
        Notifier.post(title: "Brim", body: message)
    }

    private func save() {
        guard !AppSettings.isSnapshot else { return }
        file.save(state)
    }
}

/// Local notifications, only when running as a bundled app (UserNotifications needs a bundle ID).
enum Notifier {
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static func requestIfNeeded() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard available, !AppSettings.isSnapshot else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func status(_ done: @escaping (UNAuthorizationStatus?) -> Void) {
        guard available else { return done(nil) }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { done(settings.authorizationStatus) }
        }
    }
}

// MARK: - Stats

/// Samples the Mac every two seconds while the Stats tab is open (and the battery once a minute otherwise).
@MainActor
final class StatsService: ObservableObject {
    @Published private(set) var sample = SystemSample()
    @Published private(set) var cpuHistory: [Double] = Array(repeating: 0, count: 30)
    @Published private(set) var netHistory: [Double] = Array(repeating: 0, count: 30)
    @Published private(set) var battery: BatteryInfo? = SystemMonitor.battery()
    private let monitor = SystemMonitor()
    private var timer: Timer?
    private var batteryTimer: Timer?
    private var watchers = 0

    init() {
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.battery = SystemMonitor.battery() }
        }
        if AppSettings.isSnapshot {
            _ = monitor.sample()
            Thread.sleep(forTimeInterval: 0.5)
            take()
            cpuHistory = (0..<30).map { (i: Int) -> Double in
                let x = Double(i)
                return 18.0 + 12.0 * sin(x * 0.5) + Double(i % 4) * 3.0
            }
            netHistory = (0..<30).map { (i: Int) -> Double in
                let wave: Double = abs(sin(Double(i) * 0.3))
                return 400_000.0 + 1_200_000.0 * wave
            }
        }
    }

    /// Stats views call these on appear and disappear.
    func watch() {
        watchers += 1
        guard timer == nil else { return }
        take()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.take() }
        }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    private func take() {
        let next = monitor.sample()
        sample = next
        battery = next.battery
        cpuHistory = Array((cpuHistory + [next.cpuPercent]).suffix(30))
        netHistory = Array((netHistory + [next.netDown]).suffix(30))
    }
}

enum Bytes {
    /// "11.2 GB", "480 MB".
    static func format(_ bytes: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// Per-second network speed: "1.4 MB/s", "180 KB/s".
    static func speed(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }
}

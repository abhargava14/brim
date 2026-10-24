import AppKit
import Combine
import CoreGraphics
import IslandCore

/// Counts time per app while it's in front and you're active. Only the app's bundle ID and name
/// are kept, on this Mac; window titles and contents are never read.
@MainActor
public final class ScreenTimeTracker: ObservableObject {
    @Published public private(set) var log: ScreenTimeLog
    /// Tracking happens only after you open the Screen Time tab once.
    @Published public private(set) var enabled: Bool

    private let file: JSONFile<ScreenTimeLog>
    private let persist: Bool
    private var timer: Timer?
    private var lastTick = Date()
    private var asleep = false
    private var observers: [NSObjectProtocol] = []
    private var unsaved = 0

    /// No input for this long counts as away.
    static let idleLimit: TimeInterval = 120

    public init(directory: URL = JSONFile<ScreenTimeLog>.supportDirectory, persist: Bool = true) {
        file = JSONFile("screen-time.json", directory: directory)
        self.persist = persist
        log = file.load() ?? ScreenTimeLog()
        enabled = persist && UserDefaults.standard.bool(forKey: "screenTimeEnabled")
        let center = NSWorkspace.shared.notificationCenter
        for (name, sleeping) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.willSleepNotification, true),
                                 (NSWorkspace.sessionDidResignActiveNotification, true),
                                 (NSWorkspace.screensDidWakeNotification, false), (NSWorkspace.didWakeNotification, false),
                                 (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.tick()
                    self?.asleep = sleeping
                }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            // Credit the time so far to the app that was in front until now.
            Task { @MainActor in self?.tick() }
        })
        if enabled { start() }
    }

    public func enable() {
        guard !enabled else { return }
        enabled = true
        UserDefaults.standard.set(true, forKey: "screenTimeEnabled")
        start()
    }

    public func disable() {
        enabled = false
        UserDefaults.standard.set(false, forKey: "screenTimeEnabled")
        timer?.invalidate()
        timer = nil
    }

    private func start() {
        lastTick = Date()
        frontApp = NSWorkspace.shared.frontmostApplication
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private var frontApp: NSRunningApplication?

    private func tick() {
        let now = Date()
        defer {
            lastTick = now
            frontApp = NSWorkspace.shared.frontmostApplication
        }
        guard enabled, !asleep, let app = frontApp, let id = app.bundleIdentifier else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < Self.idleLimit else { return }
        let seconds = min(now.timeIntervalSince(lastTick), 30)
        log.add(seconds: seconds, app: id, name: app.localizedName ?? id, endingAt: now)
        unsaved += 1
        if unsaved >= 6 { save() }
    }

    public func save() {
        unsaved = 0
        guard persist else { return }
        file.save(log)
    }

    /// The icon of an app by bundle ID, for the Apps list.
    public static func icon(for bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Fixture data for snapshot renders.
    public func loadSample() {
        enabled = true
        var sample = ScreenTimeLog()
        let calendar = Calendar.current
        let now = Date()
        let apps = [("com.mitchellh.ghostty", "Ghostty", 130.0), ("com.apple.dt.Xcode", "Xcode", 85), ("company.thebrowser.Browser", "Arc", 58),
                    ("com.figma.Desktop", "Figma", 41), ("com.tinyspeck.slackmacgap", "Slack", 22), ("com.apple.Music", "Music", 12)]
        for back in 0..<7 {
            let day = calendar.date(byAdding: .day, value: -back, to: now)!
            for (index, app) in apps.enumerated() {
                let hour = 9 + index * 2
                let end = calendar.date(bySettingHour: hour, minute: 50, second: 0, of: day)!
                guard end < now else { continue }
                sample.add(seconds: app.2 * 60 * (back == 0 ? 1 : 0.6 + Double((back * 7 + index) % 5) * 0.2), app: app.0, name: app.1, endingAt: end)
            }
        }
        sample.startedAt = calendar.date(byAdding: .day, value: -12, to: now)
        log = sample
    }
}

import AppKit
import AVFoundation
import IslandServices
import IslandCore
import SwiftUI

/// Renders the island's screens to PNG files with fixture data, then quits:
/// `BRIM_SNAPSHOT_DIR=/tmp/shots swift run BrimApp`. No Keychain, no network, no saved settings.
@MainActor
enum BrimSnapshot {
    struct Shot {
        let name: String
        var tab: TabID = .ai
        var appearance: IslandAppearance = .dark
        var preset: [String: String] = [:]
        var closed = false
        var settings: SettingsSection?
        var group: ConnectionGroup = .ai
        var closedMode: ClosedNotchState.Mode?
    }

    static func runIfRequested() -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["BRIM_SNAPSHOT_DIR"] else { return false }
        setenv("BRIM_QA_NO_KEYCHAIN", "1", 1)
        if ProcessInfo.processInfo.environment["BRIM_QA_FIXTURE"] == nil { setenv("BRIM_QA_FIXTURE", "rich", 1) }
        let only = ProcessInfo.processInfo.environment["BRIM_SNAPSHOT_ONLY"]
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let settings = AppSettings()
        settings.tabLayout = .standard
        let model = UsageModel(settings: settings)
        model.start()
        let hub = BrimHub(settings: settings, model: model)
        let folder = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for shot in shots where only == nil || shot.name.contains(only!) {
            settings.selectedTab = shot.tab
            settings.appearance = shot.appearance
            hub.closed.force(shot.closedMode ?? .ai)
            let view: AnyView
            if let section = shot.settings {
                view = AnyView(BrimSettingsView(hub: hub, settings: settings, model: model, section: section, group: shot.group)
                    .frame(width: 860, height: 580))
            } else {
                let state = IslandState()
                state.hasNotch = true
                state.notchWidth = 185
                state.barHeight = 32
                state.screenWidth = 1512
                state.isExpanded = !shot.closed
                view = AnyView(
                    IslandView(hub: hub, closed: hub.closed, model: model, settings: settings, state: state, openSettings: { _ in }, addAccount: { _ in })
                        .environment(\.tabPreset, shot.preset)
                        .frame(width: 1000, height: shot.closed ? 60 : 470, alignment: .top)
                        .clipped()
                        .background(LinearGradient(colors: [Color(red: 0.83, green: 0.86, blue: 0.89), Color(red: 0.71, green: 0.76, blue: 0.81)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                )
            }
            render(view, to: folder.appendingPathComponent(shot.name + ".png"))
        }
        checkSounds()
        if let path = ProcessInfo.processInfo.environment["BRIM_CHECK_JWT"],
           let json = try? String(contentsOfFile: path), let account = GoogleAnalytics.parseServiceAccount(json) {
            print("JWT " + ((try? GoogleSigner.signedJWT(account)) ?? "failed"))
        }
        print("Rendered snapshots to \(folder.path)")
        return true
    }

    /// Renders two seconds of each ambient sound offline and prints its level, so silence or noise blow-ups show.
    static func checkSounds() {
        let frames = 44_100 * 2
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { left.deallocate() }
        for sound in AmbientSound.allCases {
            let mixer = NoiseMixer()
            mixer.set(sound, 1)
            let list = AudioBufferList.allocate(maximumBuffers: 1)
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: left)
            mixer.render(frames: frames, buffers: list)
            let samples = UnsafeBufferPointer(start: left, count: frames).suffix(44_100)
            let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
            let peak = samples.map(abs).max() ?? 0
            print(String(format: "sound %-10@ rms %.3f peak %.3f%@", sound.rawValue, rms, peak, rms.isFinite && rms > 0.005 ? "" : "  <-- check"))
            free(list.unsafeMutablePointer)
        }
    }

    static func render(_ view: AnyView, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("Could not render \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
    }

    /// Every screen worth checking after a change. Later phases add their tabs here.
    static var shots: [Shot] {
        var list: [Shot] = [
            Shot(name: "closed", closed: true),
            Shot(name: "closed-music", closed: true, closedMode: .music),
            Shot(name: "closed-timer", closed: true, closedMode: .timer),
            Shot(name: "closed-scratch", closed: true, closedMode: .scratch),
            Shot(name: "closed-notice", closed: true, closedMode: .notice(.init(id: "n", symbol: "exclamationmark.circle.fill", tint: Palette.amber,
                                                                                  title: "Cursor · work", detail: "sign in again", tab: .ai, until: .distantFuture))),
            Shot(name: "ai-overview"),
            Shot(name: "ai-overview-light", appearance: .light),
            Shot(name: "ai-account-log", preset: ["ai.selected": "qa-claude-code"]),
            Shot(name: "ai-account-quota", preset: ["ai.selected": "qa-cursor"]),
            Shot(name: "ai-account-error", preset: ["ai.selected": "qa-copilot"]),
            Shot(name: "ai-add", preset: ["ai.adding": "1"]),
            Shot(name: "more-grid", preset: ["more": "1"]),
            Shot(name: "timers-pomodoro", tab: .timers),
            Shot(name: "timers-countdown", tab: .timers, preset: ["timers.sub": "countdown"]),
            Shot(name: "timers-stopwatch", tab: .timers, preset: ["timers.sub": "stopwatch"]),
            Shot(name: "timers-water", tab: .timers, preset: ["timers.sub": "water"]),
            Shot(name: "notes", tab: .notes),
            Shot(name: "links", tab: .links),
            Shot(name: "links-engines", tab: .links, preset: ["links.manage": "1"]),
            Shot(name: "stats", tab: .stats),
            Shot(name: "sounds", tab: .sounds),
            Shot(name: "units-currency", tab: .units),
            Shot(name: "units-length", tab: .units, preset: ["units.category": "length"]),
            Shot(name: "scratchpad", tab: .scratchpad),
            Shot(name: "timers-light", tab: .timers, appearance: .light),
            Shot(name: "home", tab: .home),
            Shot(name: "home-light", tab: .home, appearance: .light),
            Shot(name: "calendar-week", tab: .calendar, preset: ["calendar.sub": "week"]),
            Shot(name: "calendar-day", tab: .calendar, preset: ["calendar.sub": "day"]),
            Shot(name: "calendar-month", tab: .calendar, preset: ["calendar.sub": "month"]),
            Shot(name: "calendar-reminders", tab: .calendar, preset: ["calendar.sub": "reminders"]),
            Shot(name: "weather", tab: .weather),
            Shot(name: "screen-today", tab: .screen),
            Shot(name: "screen-week", tab: .screen, preset: ["screen.sub": "week"]),
            Shot(name: "clipboard", tab: .clipboard),
            Shot(name: "files", tab: .files),
            Shot(name: "analytics", tab: .analytics),
            Shot(name: "analytics-light", tab: .analytics, appearance: .light),

        ]
        for section in SettingsSection.allCases {
            list.append(Shot(name: "settings-\(section.rawValue)", settings: section))
        }
        list.append(Shot(name: "settings-light", appearance: .light, settings: .connections))
        for group in [ConnectionGroup.music, .calendar, .weather, .analytics] {
            list.append(Shot(name: "settings-conn-\(group.rawValue)", settings: .connections, group: group))
        }
        return list
    }
}

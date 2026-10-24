import AppKit
import Combine

/// What's playing in Spotify or Music on this Mac. Track changes arrive as distributed
/// notifications, which need no permission; play, pause, skip and the playhead use AppleScript,
/// which asks for Automation access once per player.
@MainActor
public final class NowPlaying: ObservableObject {
    public enum Player: String, CaseIterable, Sendable {
        case spotify, music

        public var title: String { self == .spotify ? "Spotify" : "Apple Music" }
        public var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
        var scriptName: String { self == .spotify ? "Spotify" : "Music" }
    }

    public struct Track: Equatable, Sendable {
        public var title: String
        public var artist: String
        public var album: String
        public var duration: Double
        public var position: Double
        public var playing: Bool
        public var player: Player
        public var positionAt: Date

        /// The playhead now, moving on while playing.
        public func elapsed(at now: Date = Date()) -> Double {
            min(duration, position + (playing ? now.timeIntervalSince(positionAt) : 0))
        }
    }

    @Published public private(set) var track: Track?
    @Published public private(set) var artwork: NSImage?
    /// Automation was refused for a player, so controls can't work.
    @Published public private(set) var denied: Set<Player> = []
    /// The user allowed play/pause and artwork, which needs Automation; until then only
    /// notifications are read and macOS never asks.
    @Published public var controlsEnabled = UserDefaults.standard.bool(forKey: "musicControls") {
        didSet {
            UserDefaults.standard.set(controlsEnabled, forKey: "musicControls")
            if controlsEnabled { syncPosition() }
        }
    }

    private var observers: [NSObjectProtocol] = []
    private var artworkURL: String?
    private var timer: Timer?

    public init() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            Task { @MainActor in self?.receive(info, from: .spotify) }
        })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            Task { @MainActor in self?.receive(info, from: .music) }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncPosition() }
        }
        // Pick up a song that started before Brim did.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.syncPosition() }
    }

    /// Players installed on this Mac.
    public static func installed(_ player: Player) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) != nil
    }

    static func running(_ player: Player) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty
    }

    private func receive(_ info: [AnyHashable: Any], from player: Player) {
        let state = (info["Player State"] as? String) ?? ""
        guard state != "Stopped", let name = info["Name"] as? String else {
            if track?.player == player { track = nil; artwork = nil }
            return
        }
        // Spotify reports milliseconds, Music milliseconds as "Total Time".
        let duration = ((info["Duration"] as? NSNumber)?.doubleValue ?? (info["Total Time"] as? NSNumber)?.doubleValue ?? 0) / 1000
        let position = (info["Playback Position"] as? NSNumber)?.doubleValue ?? (track?.title == name ? track?.elapsed() ?? 0 : 0)
        track = Track(title: name, artist: info["Artist"] as? String ?? "", album: info["Album"] as? String ?? "",
                      duration: duration, position: position, playing: state == "Playing", player: player, positionAt: Date())
        loadArtwork(player)
    }

    /// Asks the player for the playhead (and the song, if Brim started mid-song).
    public func syncPosition() {
        for player in Player.allCases where Self.running(player) {
            guard controlsEnabled, canAsk("NSAppleEventsUsageDescription"), !denied.contains(player) else { continue }
            let script = """
            tell application "\(player.scriptName)"
                if player state is stopped then return ""
                set t to current track
                return (name of t) & "\\n" & (artist of t) & "\\n" & (album of t) & "\\n" & (duration of t) & "\\n" & (player position) & "\\n" & (player state as string)
            end tell
            """
            guard let output = run(script, player: player), !output.isEmpty else { continue }
            let parts = output.components(separatedBy: "\n")
            guard parts.count >= 6 else { continue }
            var duration = Double(parts[3].replacingOccurrences(of: ",", with: ".")) ?? 0
            if player == .spotify { duration /= 1000 }
            track = Track(title: parts[0], artist: parts[1], album: parts[2], duration: duration,
                          position: Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0,
                          playing: parts[5] == "playing", player: player, positionAt: Date())
            loadArtwork(player)
            return
        }
    }

    public func playPause() { control("playpause") }
    public func next() { control("next track") }
    public func previous() { control("previous track") }

    private func control(_ command: String) {
        guard let player = track?.player else { return }
        _ = run("tell application \"\(player.scriptName)\" to \(command)", player: player)
        if command == "playpause", var current = track {
            current.position = current.elapsed()
            current.positionAt = Date()
            current.playing.toggle()
            track = current
        }
    }

    private func run(_ source: String, player: Player) -> String? {
        guard controlsEnabled, canAsk("NSAppleEventsUsageDescription") else { return nil }
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let code = error?[NSAppleScript.errorNumber] as? Int, code == -1743 {
            denied.insert(player)
            return nil
        }
        denied.remove(player)
        return result?.stringValue
    }

    /// Spotify gives an artwork URL; Music hands over the image data.
    private func loadArtwork(_ player: Player) {
        guard controlsEnabled, canAsk("NSAppleEventsUsageDescription"), !denied.contains(player), Self.running(player) else { return }
        if player == .spotify {
            guard let url = run("tell application \"Spotify\" to return artwork url of current track", player: player),
                  url != artworkURL, let link = URL(string: url) else { return }
            artworkURL = url
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: link), let image = NSImage(data: data) else { return }
                self.artwork = image
            }
        } else {
            let key = track.map { "\($0.title)|\($0.album)" }
            guard key != artworkURL else { return }
            artworkURL = key
            var error: NSDictionary?
            let descriptor = NSAppleScript(source: "tell application \"Music\" to return data of artwork 1 of current track")?.executeAndReturnError(&error)
            artwork = descriptor.flatMap { NSImage(data: $0.data) }
        }
    }

    public func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    /// Fixture data for snapshot renders.
    public func loadSample() {
        track = Track(title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming", duration: 243, position: 102,
                      playing: true, player: .spotify, positionAt: Date())
    }
}

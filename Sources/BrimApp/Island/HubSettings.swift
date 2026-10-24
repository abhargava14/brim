import AppKit
import IslandCore
import IslandSystem
import SwiftUI
import UserNotifications

// What each service contributes to Settings: its Connections group and its macOS permissions.

extension BrimHub {
    @ViewBuilder
    func connectionsPage(_ group: ConnectionGroup) -> some View {
        switch group {
        case .ai: EmptyView()
        case .music: MusicConnections(music: music)
        case .calendar: CalendarConnections(calendar: calendar)
        case .weather: WeatherConnections(weather: weather)
        case .analytics: AnalyticsConnections(analytics: analytics)
        }
    }

    func permissions() -> [PermissionInfo] {
        func state(_ access: Access) -> PermissionInfo.State {
            switch access {
            case .allowed: return .allowed
            case .denied: return .denied
            case .notAsked, .unavailable: return .notAsked
            }
        }
        let musicDenied = !music.denied.isEmpty
        return [
            PermissionInfo(title: "Calendars and Reminders", detail: "Calendar tab, Up next on Home", state: state(calendar.access),
                           action: calendar.access == .allowed || calendar.access == .unavailable ? nil : { [calendar] in calendar.request() }),
            PermissionInfo(title: "Location", detail: "Weather tab · city-level only", state: state(weather.access),
                           action: weather.access == .allowed || weather.access == .unavailable ? nil : { [weather] in
                               if weather.access == .denied { Self.openPrivacy("Privacy_LocationServices") } else { weather.useMyLocation() }
                           }),
            PermissionInfo(title: "Automation · Music and Spotify", detail: "Play, pause, skip and artwork on Home",
                           state: musicDenied ? .denied : music.controlsEnabled ? .allowed : .notAsked,
                           action: musicDenied ? { [music] in music.openAutomationSettings() } : music.controlsEnabled ? nil : { [music] in music.controlsEnabled = true }),
            PermissionInfo(title: "Notifications", detail: "Timer finished, hydration reminders",
                           state: notificationsAllowed == true ? .allowed : notificationsAllowed == false ? .denied : .notAsked,
                           action: notificationsAllowed == true ? nil : { Notifier.requestIfNeeded(); Self.openPrivacy("Notifications") }),
            PermissionInfo(title: "Files in your home folder",
                           detail: "Reads ~/.claude and ~/.codex for token counts. No Full Disk Access needed.", state: .allowed),
        ]
    }

    static func openPrivacy(_ anchor: String) {
        let url = anchor == "Notifications"
            ? URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
            : URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        NSWorkspace.shared.open(url)
    }
}

/// A row in a Connections group: tile, name, line under it, status and one fix.
struct ConnectionLine<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var divider = true
    @ViewBuilder var trailing: Trailing
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(theme.fg)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.f(0.1)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.brim(13, .bold))
                Text(detail).font(.brim(11.5, .medium)).foregroundStyle(theme.f(0.5)).lineLimit(2)
            }
            Spacer(minLength: 10)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .top) {
            if divider { Rectangle().fill(theme.f(0.07)).frame(height: 1) }
        }
    }
}

private struct Intro: View {
    let text: String
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Text(text).font(.brim(12.5, .medium)).foregroundStyle(theme.f(0.6)).fixedSize(horizontal: false, vertical: true)
    }
}

struct MusicConnections: View {
    @ObservedObject var music: NowPlaying

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Intro(text: "Now playing on Home and in the closed notch. Brim shows one player at a time, whichever played last. Song names need no permission; play, pause, skip and artwork use Automation.")
            SettingsGroup {
                ForEach(Array(NowPlaying.Player.allCases.enumerated()), id: \.offset) { index, player in
                    let installed = NowPlaying.installed(player)
                    let denied = music.denied.contains(player)
                    ConnectionLine(symbol: player == .spotify ? "dot.radiowaves.left.and.right" : "music.note",
                                   tint: player == .spotify ? Color(red: 0.11, green: 0.73, blue: 0.33) : Color(red: 0.98, green: 0.18, blue: 0.28),
                                   title: player.title,
                                   detail: !installed ? "Not installed on this Mac" : denied ? "Automation not allowed, so controls are off" : "Uses the \(player == .spotify ? "Spotify" : "Music") app on this Mac",
                                   divider: index > 0) {
                        StatusPill(text: !installed ? "Not installed" : denied ? "Needs attention" : music.controlsEnabled ? "Connected" : "Song only",
                                   kind: !installed ? .off : denied ? .warn : music.controlsEnabled ? .ok : .off)
                        if denied {
                            IslandButton(title: "Allow", style: .tint(Palette.amber), height: 26, fontSize: 11.5) { music.openAutomationSettings() }
                        }
                    }
                }
                SettingsRow(title: "Player controls and artwork", sub: "macOS asks once per player the first time Brim controls it") {
                    IslandSwitch(isOn: $music.controlsEnabled, label: "Player controls")
                }
            }
        }
    }
}

struct CalendarConnections: View {
    @ObservedObject var calendar: CalendarReader

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Intro(text: "Brim reads the calendars already on this Mac, including Google and Exchange accounts added in System Settings › Internet Accounts. It never asks for your Google password.")
                Spacer(minLength: 16)
                IslandButton(title: "Add account in System Settings", height: 28, fontSize: 11.5) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
                }
            }
            SettingsGroup {
                ConnectionLine(symbol: "checkmark", tint: Palette.green, title: "Calendar access",
                               detail: calendar.access == .allowed ? "Allowed · events and reminders" : calendar.access == .denied ? "Turned off in Privacy & Security" : "Not asked yet",
                               divider: false) {
                    StatusPill(text: calendar.access == .allowed ? "Connected" : calendar.access == .denied ? "Needs attention" : "Not connected",
                               kind: calendar.access == .allowed ? .ok : calendar.access == .denied ? .warn : .off)
                    if calendar.access != .allowed, calendar.access != .unavailable {
                        IslandButton(title: calendar.access == .denied ? "Open System Settings" : "Allow", style: calendar.access == .denied ? .tint(Palette.amber) : .primary,
                                     height: 26, fontSize: 11.5) { calendar.request() }
                    }
                }
                ForEach(calendar.accounts) { account in
                    ConnectionLine(symbol: "calendar", tint: Color(rgb: account.color), title: account.name,
                                   detail: "\(account.calendars) calendar\(account.calendars == 1 ? "" : "s")") {
                        StatusPill(text: "Connected", kind: .ok)
                    }
                }
            }
        }
    }
}

struct WeatherConnections: View {
    @ObservedObject var weather: WeatherService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Intro(text: "Forecast for where you are, from Open-Meteo (open data, no account). If location is off, Brim uses the city you pick in the Weather tab.")
            SettingsGroup {
                ConnectionLine(symbol: "location.fill", tint: Palette.blue, title: "Location",
                               detail: weather.access == .allowed ? "Allowed · city-level only" + (weather.useLocation ? "" : " · not in use") : weather.access == .denied ? "Turned off in Privacy & Security" : "Not asked yet",
                               divider: false) {
                    StatusPill(text: weather.access == .allowed ? "Connected" : weather.access == .denied ? "Denied" : "Not connected",
                               kind: weather.access == .allowed ? .ok : weather.access == .denied ? .denied : .off)
                    if weather.access == .notAsked || (weather.access == .allowed && !weather.useLocation) {
                        IslandButton(title: "Use my location", style: .primary, height: 26, fontSize: 11.5) { weather.useMyLocation() }
                    }
                }
                ConnectionLine(symbol: "mappin", tint: Color(white: 0.45), title: "City",
                               detail: weather.place.map { "\($0.name), \($0.region)" } ?? "None picked") {
                    EmptyView()
                }
                SettingsRow(title: "Units") {
                    SegmentedPills(options: [(false, "°C · km/h"), (true, "°F · mph")], selection: $weather.fahrenheit, look: .strong, height: 24)
                }
            }
        }
    }
}

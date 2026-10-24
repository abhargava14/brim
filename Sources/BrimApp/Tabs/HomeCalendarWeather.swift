import AppKit
import IslandCore
import IslandSystem
import SwiftUI

extension Color {
    init(rgb: [Double]) {
        self.init(red: rgb.first ?? 0, green: rgb.count > 1 ? rgb[1] : 0, blue: rgb.count > 2 ? rgb[2] : 0)
    }
}

enum When {
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// "in 31m", "in 2h 5m", "now".
    static func until(_ date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 60 { return "now" }
        return "in " + Clock.hm(seconds)
    }

    static func dayAndTime(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return time(date) }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE jj:mm")
        return formatter.string(from: date)
    }
}

// MARK: - Home

/// Home: now playing, up next and a launcher, with a glance row underneath.
struct HomeTabView: View {
    @ObservedObject var hub: BrimHub
    @ObservedObject var music: NowPlaying
    @ObservedObject var calendar: CalendarReader
    @ObservedObject var launcher: LauncherService
    @ObservedObject var timers: TimerService
    @ObservedObject var weather: WeatherService
    @ObservedObject var model: UsageModel
    let go: (TabID) -> Void
    @State private var editing = false
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            WeightedColumns(weights: [1.3, 1, 1]) {
                nowPlaying
                upNext
                launch
            }
            HStack(spacing: 10) {
                ForEach(glance, id: \.0) { item in
                    HStack(spacing: 9) {
                        Image(systemName: item.1).font(.system(size: 13, weight: .semibold)).opacity(0.7)
                        Text(item.2).font(.brim(14)).foregroundStyle(item.3 ?? theme.fg).lineLimit(1).fixedSize()
                        Text(item.4).font(.brim(11.5, .bold)).foregroundStyle(theme.f(0.5)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .hoverFill(15, base: theme.f(0.06), hover: theme.f(0.11))
                    .onTapGesture { go(item.0) }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                }
            }
        }
    }

    // MARK: Now playing

    private var nowPlaying: some View {
        IslandCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Now playing", aside: music.track?.player.title)
                if let track = music.track {
                    HStack(spacing: 14) {
                        Group {
                            if let art = music.artwork {
                                Image(nsImage: art).resizable().scaledToFill()
                            } else {
                                ZStack {
                                    Color(red: 0.75, green: 0.36, blue: 0.29)
                                    Image(systemName: "music.note").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                                }
                            }
                        }
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title).font(.brim(17)).lineLimit(1)
                            Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.brim(12, .bold)).foregroundStyle(theme.f(0.55)).lineLimit(1)
                        }
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = track.elapsed(at: context.date)
                        VStack(spacing: 5) {
                            MiniBar(fraction: track.duration > 0 ? elapsed / track.duration : 0, height: 4)
                            HStack {
                                Text(Clock.mmss(elapsed).trimmingLeadingZero)
                                Spacer()
                                Text("-" + Clock.mmss(max(0, track.duration - elapsed)).trimmingLeadingZero)
                            }
                            .font(.brim(10.5, .bold))
                            .foregroundStyle(theme.f(0.45))
                            .monospacedDigit()
                        }
                    }
                    if !music.controlsEnabled {
                        HStack {
                            Spacer()
                            IslandButton(title: "Allow play and pause", height: 28, fontSize: 11.5) { music.controlsEnabled = true }
                            Spacer()
                        }
                    } else {
                    HStack(spacing: 12) {
                        Spacer()
                        transport("backward.end.fill", "Previous") { music.previous() }
                        Image(systemName: track.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 40, height: 40)
                            .foregroundStyle(theme.bg)
                            .background(Circle().fill(theme.fg))
                            .onTapGesture { music.playPause() }
                            .accessibilityLabel(track.playing ? "Pause" : "Play")
                            .accessibilityAddTraits(.isButton)
                        transport("forward.end.fill", "Next") { music.next() }
                        Spacer()
                    }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Spacer(minLength: 0)
                        Text("Nothing playing").font(.brim(15))
                        Text("Play something in Spotify or Music and it shows here and in the closed notch.")
                            .font(.brim(12, .bold)).foregroundStyle(theme.f(0.55)).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            if NowPlaying.installed(.spotify) {
                                IslandButton(title: "Open Spotify", style: .tint(Color(red: 0.11, green: 0.73, blue: 0.33))) { open(.spotify) }
                            }
                            IslandButton(title: "Open Music") { open(.music) }
                        }
                        .padding(.top, 4)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func open(_ player: NowPlaying.Player) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func transport(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .frame(width: 32, height: 32)
            .hoverFill(16, hover: theme.f(0.1))
            .onTapGesture(perform: action)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }

    // MARK: Up next

    private var upNext: some View {
        IslandCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(title: "Up next")
                    if let next = calendar.nextEvent, calendar.access == .allowed {
                        Text(next.start > Date() ? When.until(next.start) : "now").font(.brim(11, .bold)).foregroundStyle(Palette.green).fixedSize()
                    }
                }
                switch calendar.access {
                case .allowed:
                    if let next = calendar.nextEvent {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(next.title).font(.brim(16)).lineLimit(2)
                            Text("\(When.time(next.start)) – \(When.time(next.end))" + (next.meeting.map { " · " + MeetingLink.service($0) } ?? next.location.map { " · " + $0 } ?? ""))
                                .font(.brim(12, .bold)).foregroundStyle(theme.f(0.6)).lineLimit(1)
                        }
                        if let meeting = next.meeting {
                            IslandButton(title: "Join", style: .tint(Palette.green), height: 28) { NSWorkspace.shared.open(meeting) }
                        }
                        Rectangle().fill(theme.f(0.08)).frame(height: 1)
                        SectionTitle(title: "Later", opacity: 0.45)
                        ForEach(calendar.events.filter { !$0.allDay && $0.start > next.start }.prefix(2)) { event in
                            HStack(spacing: 8) {
                                Circle().fill(Color(rgb: event.color)).frame(width: 6, height: 6)
                                Text(When.dayAndTime(event.start)).foregroundStyle(theme.f(0.5)).fixedSize()
                                Text(event.title).lineLimit(1)
                            }
                            .font(.brim(12, .bold))
                        }
                    } else {
                        Spacer(minLength: 0)
                        Text("Nothing else this week").font(.brim(15))
                        Text("Enjoy the quiet.").font(.brim(12, .bold)).foregroundStyle(theme.f(0.55))
                        Spacer(minLength: 0)
                    }
                case .denied:
                    inlinePrompt(title: "Calendar access is off", tint: Palette.amber,
                                 body: "Turn Brim on in Privacy & Security › Calendars.", button: "Open System Settings", primary: false) { calendar.openSettings() }
                case .notAsked:
                    inlinePrompt(title: "See your next event", tint: nil, body: "Brim reads the calendars already on this Mac.",
                                 button: calendar.waiting ? "Waiting for macOS…" : "Allow access", primary: true) { calendar.request() }
                case .unavailable:
                    inlinePrompt(title: "See your next event", tint: nil, body: "Install Brim in Applications to connect your calendars.",
                                 button: nil, primary: false) {}
                }
            }
        }
    }

    private func inlinePrompt(title: String, tint: Color?, body: String, button: String?, primary: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer(minLength: 0)
            Text(title).font(.brim(15)).foregroundStyle(tint ?? theme.fg)
            Text(body).font(.brim(12, .bold)).foregroundStyle(theme.f(0.55)).fixedSize(horizontal: false, vertical: true)
            if let button {
                IslandButton(title: button, style: primary ? .primary : .secondary, action: action).padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Launch

    private var launch: some View {
        IslandCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle(title: "Launch")
                    Text(editing ? "Done" : "Edit")
                        .font(.brim(11, .bold))
                        .foregroundStyle(theme.f(0.5))
                        .onTapGesture { editing.toggle() }
                        .accessibilityAddTraits(.isButton)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 12) {
                    ForEach(launcher.apps, id: \.self) { app in
                        VStack(spacing: 5) {
                            Image(nsImage: LauncherService.icon(app))
                                .resizable()
                                .frame(width: 40, height: 40)
                                .frame(width: 44, height: 44)
                                .overlay(alignment: .topTrailing) {
                                    if editing {
                                        Image(systemName: "minus.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.white, Palette.red)
                                            .onTapGesture { launcher.remove(app) }
                                            .accessibilityLabel("Remove \(LauncherService.name(app))")
                                    }
                                }
                            Text(LauncherService.name(app)).font(.brim(11, .bold)).foregroundStyle(theme.f(0.6)).lineLimit(1)
                        }
                        .onTapGesture { editing ? launcher.choose(replacing: app) : launcher.launch(app) }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                    }
                    if launcher.apps.count < 6 {
                        VStack(spacing: 5) {
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .bold))
                                .frame(width: 44, height: 44)
                                .hoverFill(12, base: theme.f(0.1), hover: theme.f(0.18))
                            Text("Add").font(.brim(11, .bold)).foregroundStyle(theme.f(0.6))
                        }
                        .onTapGesture { launcher.choose(replacing: nil) }
                        .accessibilityAddTraits(.isButton)
                    }
                }
            }
        }
    }

    // MARK: Glance

    private var glance: [(TabID, String, String, Color?, String)] {
        var items: [(TabID, String, String, Color?, String)] = []
        let accounts = AIAccounts(model: model, settings: hub.settings)
        if let near = accounts.items.filter({ $0.lead != nil }).max(by: { ($0.lead ?? 0) < ($1.lead ?? 0) }), let lead = near.lead {
            let window = near.tool?.tightestWindow
            items.append((.ai, "sparkle", Format.percent(lead), Palette.warm(lead),
                          "\(near.name) \(window.map { AIAccountDetail.shortLabel($0) } ?? "") · \(window?.resetsAt.map { Format.countdown(to: $0) } ?? "")"))
        } else {
            items.append((.ai, "sparkle", Format.tokens(model.snapshot.todayTokens), nil, "tokens today"))
        }
        if let forecast = weather.forecast {
            items.append((.weather, OpenMeteo.symbol(forecast.current.code, isDay: forecast.current.isDay), "\(Int(forecast.current.temperature.rounded()))°", nil, OpenMeteo.describe(forecast.current.code)))
        } else {
            items.append((.weather, "cloud.sun", "–", nil, "Set up weather"))
        }
        let state = timers.state
        items.append((.timers, "timer", state.pomodoroRunning ? Clock.mmss(state.pomodoroRemaining(at: timers.now)) : Clock.mmss(state.phaseLength(.focus)),
                      state.pomodoroRunning ? Palette.coral : nil, state.pomodoroRunning ? "\(state.phase.title) running" : "Start focus"))
        let today = hub.screenTime.log.day(Date()).total
        items.append((.screen, "hourglass", hub.screenTime.enabled ? Clock.hm(today) : "–", nil, "screen time"))
        return items
    }
}

extension String {
    /// "02:41" → "2:41".
    var trimmingLeadingZero: String { hasPrefix("0") && count == 5 ? String(dropFirst()) : self }
}

// MARK: - Calendar

/// Calendar: a seven-day agenda, and reminders you can tick off or add with Return.
struct CalendarTabView: View {
    enum Sub: String { case agenda, reminders }

    @ObservedObject var calendar: CalendarReader
    @State private var sub: Sub
    @State private var draft = ""
    @Environment(\.islandTheme) private var theme

    init(calendar: CalendarReader, sub: String? = nil) {
        self.calendar = calendar
        _sub = State(initialValue: sub.flatMap(Sub.init(rawValue:)) ?? .agenda)
    }

    var body: some View {
        switch calendar.access {
        case .notAsked, .unavailable:
            ConnectCard(symbol: "calendar", color: Palette.blue, title: "See your week here",
                        message: "Brim reads the calendars already on this Mac: iCloud, Google, Exchange and any others you added in System Settings › Internet Accounts.",
                        actions: calendar.access == .unavailable ? [] : [.init(title: "Allow calendar access") { calendar.request() }],
                        waiting: calendar.waiting ? "macOS is asking…" : nil,
                        note: calendar.access == .unavailable ? "Install Brim in Applications so macOS can ask for access." : "macOS asks once. Reminders use the same permission.")
        case .denied:
            ConnectCard(symbol: "calendar", color: Palette.amber, title: "Calendar access is off",
                        message: "You chose Don't Allow earlier, so macOS hides your events from Brim. Turn Brim on in System Settings › Privacy & Security › Calendars.",
                        actions: [.init(title: "Open System Settings") { calendar.openSettings() }],
                        note: "Brim picks up the change as soon as you flip the switch.")
        case .allowed:
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    SegmentedPills(options: [(Sub.agenda, "Agenda"), (.reminders, "Reminders")], selection: $sub)
                    Spacer()
                    ForEach(calendar.accounts.prefix(4)) { account in
                        HStack(spacing: 6) {
                            Circle().fill(Color(rgb: account.color)).frame(width: 7, height: 7)
                            Text(account.name).lineLimit(1)
                        }
                        .font(.brim(11.5))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(theme.f(0.06)))
                    }
                }
                if sub == .agenda { agenda } else { reminders }
            }
        }
    }

    private var agenda: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { offset in
                let day = cal.date(byAdding: .day, value: offset, to: today)!
                let events = calendar.events.filter { cal.isDate($0.start, inSameDayAs: day) }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(formatter.string(from: day)).font(.brim(11)).foregroundStyle(theme.f(0.5))
                        Text("\(cal.component(.day, from: day))").font(.brim(17)).foregroundStyle(offset == 0 ? Palette.red : theme.fg)
                    }
                    .padding(.horizontal, 3)
                    if events.isEmpty {
                        Text("Nothing yet").font(.brim(11, .bold)).foregroundStyle(theme.f(0.35)).padding(.horizontal, 3)
                    }
                    ForEach(events.prefix(5)) { event in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.allDay ? "All day" : When.time(event.start)).font(.brim(10.5)).foregroundStyle(Color(rgb: event.color))
                            Text(event.title).font(.brim(11.5)).lineLimit(2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(rgb: event.color).opacity(0.16)))
                        .opacity(event.end < Date() ? 0.5 : 1)
                        .onTapGesture { if let meeting = event.meeting { NSWorkspace.shared.open(meeting) } }
                        .help(event.meeting.map { "Join on \(MeetingLink.service($0))" } ?? event.calendar)
                    }
                    if events.count > 5 {
                        Text("+\(events.count - 5) more").font(.brim(10.5, .bold)).foregroundStyle(theme.f(0.45)).padding(.horizontal, 3)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.f(offset == 0 ? 0.09 : 0.05)))
            }
        }
    }

    @ViewBuilder
    private var reminders: some View {
        if calendar.reminderAccess != .allowed {
            ConnectCard(symbol: "checklist", color: Palette.blue, title: "Reminders need access too",
                        message: "Allow Reminders in System Settings › Privacy & Security › Reminders.",
                        actions: [.init(title: calendar.reminderAccess == .notAsked ? "Allow reminders" : "Open System Settings") { calendar.request() }])
        } else {
            let done = calendar.reminders.filter(\.done).count
            HStack(spacing: 10) {
                IslandCard(padding: EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)) {
                    VStack(spacing: 2) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus").font(.system(size: 10, weight: .bold)).opacity(0.5)
                            PlainTextField("New reminder, press Return", text: $draft) {
                                calendar.addReminder(draft)
                                draft = ""
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 11).fill(theme.f(0.06)))
                        .padding(.bottom, 4)
                        IslandScroll {
                            VStack(spacing: 2) {
                                ForEach(calendar.reminders) { reminder in
                                    HStack(spacing: 10) {
                                        ZStack {
                                            Circle().strokeBorder(reminder.done ? Palette.green : theme.f(0.35), lineWidth: 1.6)
                                            if reminder.done {
                                                Circle().fill(Palette.green)
                                                Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.black)
                                            }
                                        }
                                        .frame(width: 16, height: 16)
                                        Text(reminder.title).font(.brim(12.5, .bold)).strikethrough(reminder.done).opacity(reminder.done ? 0.45 : 1).lineLimit(1)
                                        Spacer()
                                        Text(dueText(reminder.due)).font(.brim(11)).foregroundStyle(dueColor(reminder))
                                    }
                                    .padding(.horizontal, 8)
                                    .frame(height: 32)
                                    .hoverFill(11, hover: theme.f(0.06))
                                    .onTapGesture { calendar.toggle(reminder.id) }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityValue(reminder.done ? "Done" : "Not done")
                                }
                            }
                        }
                    }
                }
                IslandCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "Today")
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(done)").font(.brim(30))
                            Text("of \(calendar.reminders.count) done").font(.brim(13, .bold)).foregroundStyle(theme.f(0.5))
                        }
                        MiniBar(fraction: calendar.reminders.isEmpty ? 0 : Double(done) / Double(calendar.reminders.count), color: Palette.green, height: 6)
                        Rectangle().fill(theme.f(0.08)).frame(height: 1).padding(.vertical, 4)
                        SectionTitle(title: "Lists")
                        ForEach(Dictionary(grouping: calendar.reminders.filter { !$0.done }, by: \.list).sorted { $0.key < $1.key }, id: \.key) { list, items in
                            HStack(spacing: 8) {
                                Circle().fill(Color(rgb: items.first?.color ?? [])).frame(width: 7, height: 7)
                                Text(list)
                                Spacer()
                                Text("\(items.count)").font(.brim(12.5))
                            }
                            .font(.brim(12.5, .bold))
                        }
                    }
                }
                .frame(width: 300)
            }
        }
    }

    private func dueText(_ date: Date?) -> String {
        guard let date else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let components = cal.dateComponents([.hour, .minute], from: date)
            return components.hour == 0 && components.minute == 0 ? "Today" : When.time(date)
        }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(date.timeIntervalSinceNow < 6 * 86_400 ? "EEE" : "d MMM")
        return formatter.string(from: date)
    }

    private func dueColor(_ reminder: ReminderItem) -> Color {
        guard !reminder.done, let due = reminder.due else { return theme.f(0.45) }
        return due < Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400) ? Palette.amber : theme.f(0.45)
    }
}

// MARK: - Weather

/// Weather: now, the next hours and seven days, for your location or a city you pick.
struct WeatherTabView: View {
    @ObservedObject var weather: WeatherService
    @State private var query = ""
    @State private var results: [OpenMeteo.Place] = []
    @State private var picking = false
    @Environment(\.islandTheme) private var theme

    var body: some View {
        if let forecast = weather.forecast, !picking {
            VStack(spacing: 8) {
                if weather.stale {
                    WarnBanner(title: "Couldn't refresh", message: "The weather service didn't answer. This forecast is from \(When.time(forecast.fetchedAt)).",
                               button: "Retry") { weather.refresh() }
                }
                content(forecast)
            }
        } else {
            setup
        }
    }

    private func content(_ f: Forecast) -> some View {
        HStack(spacing: 10) {
            IslandCard(padding: EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(f.place).font(.brim(13))
                        Image(systemName: weather.useLocation ? "location.fill" : "mappin").font(.system(size: 9)).opacity(0.5)
                        Spacer()
                        Text("updated \(When.time(f.fetchedAt))").font(.brim(11, .bold)).foregroundStyle(theme.f(0.4))
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 22, height: 22)
                            .hoverFill(11, hover: theme.f(0.1))
                            .onTapGesture { picking = true }
                            .help("Change city")
                            .accessibilityLabel("Change city")
                    }
                    HStack(spacing: 14) {
                        Image(systemName: OpenMeteo.symbol(f.current.code, isDay: f.current.isDay))
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 44))
                        Text("\(Int(f.current.temperature.rounded()))°").font(.brim(58)).kerning(-1.5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(OpenMeteo.describe(f.current.code)).font(.brim(15))
                            if let today = f.days.first {
                                Text("H \(Int(today.high.rounded()))° · L \(Int(today.low.rounded()))°").font(.brim(12, .bold)).foregroundStyle(theme.f(0.55))
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        detail("Feels like", "\(Int(f.current.feelsLike.rounded()))°")
                        detail("Humidity", "\(Int(f.current.humidity))%")
                        detail("Wind", "\(Int(f.current.windSpeed.rounded())) \(weather.fahrenheit ? "mph" : "km/h")")
                        detail("UV", "\(Int(f.current.uvIndex.rounded()))")
                    }
                    HStack(spacing: 4) {
                        ForEach(Array(f.upcomingHours().enumerated()), id: \.offset) { index, hour in
                            VStack(spacing: 5) {
                                Text(index == 0 ? "Now" : Self.hour(hour.time)).font(.brim(10.5, .bold)).foregroundStyle(theme.f(0.5))
                                Image(systemName: OpenMeteo.symbol(hour.code)).symbolRenderingMode(.multicolor).font(.system(size: 14))
                                Text("\(Int(hour.temperature.rounded()))°").font(.brim(12.5))
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            IslandCard(padding: EdgeInsets(top: 14, leading: 14, bottom: 8, trailing: 14)) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionTitle(title: "7-day forecast").padding(.horizontal, 4).padding(.bottom, 6)
                    let lowest = f.days.map(\.low).min() ?? 0, highest = f.days.map(\.high).max() ?? 1
                    ForEach(Array(f.days.enumerated()), id: \.offset) { index, day in
                        HStack(spacing: 10) {
                            Text(index == 0 ? "Today" : Self.weekday(day.date)).frame(width: 44, alignment: .leading)
                            Image(systemName: OpenMeteo.symbol(day.code)).symbolRenderingMode(.multicolor).font(.system(size: 14)).frame(width: 20)
                            Text("\(Int(day.low.rounded()))°").foregroundStyle(theme.f(0.5)).frame(width: 30, alignment: .trailing)
                            GeometryReader { geo in
                                let span = max(highest - lowest, 1)
                                ZStack(alignment: .leading) {
                                    Capsule().fill(theme.f(0.08))
                                    Capsule()
                                        .fill(LinearGradient(colors: [Palette.cyan, Palette.yellow], startPoint: .leading, endPoint: .trailing))
                                        .frame(width: max(6, geo.size.width * (day.high - day.low) / span))
                                        .offset(x: geo.size.width * (day.low - lowest) / span)
                                }
                            }
                            .frame(height: 5)
                            Text("\(Int(day.high.rounded()))°").frame(width: 30, alignment: .leading)
                        }
                        .font(.brim(12.5))
                        .padding(.horizontal, 4)
                        .frame(height: 34)
                    }
                }
            }
            .frame(width: 350)
        }
    }

    private func detail(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key.uppercased()).font(.brim(10)).kerning(1).foregroundStyle(theme.f(0.45))
            Text(value).font(.brim(14))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.f(0.06)))
    }

    private var setup: some View {
        VStack(spacing: 10) {
            ConnectCard(symbol: "cloud.sun", color: Palette.cyan, title: "Where should the forecast be for?",
                        message: "Allow location for city-level weather, or pick a city yourself. Brim never stores where you are.",
                        actions: weather.access == .unavailable ? [] : [.init(title: "Use my location") { weather.useMyLocation(); picking = false }],
                        waiting: weather.loading ? "Getting the forecast…" : nil,
                        note: weather.access == .denied ? "Location is off for Brim in System Settings, so pick a city." : "Forecasts come from Open-Meteo, an open weather service.")
            HStack(spacing: 8) {
                IslandField(placeholder: "Search for a city", text: $query, symbol: "magnifyingglass", height: 34, fontSize: 13) { search() }
                    .onChange(of: query) { _ in search() }
                if picking {
                    IslandButton(title: "Cancel", height: 34) { picking = false }
                }
            }
            if !results.isEmpty {
                HStack(spacing: 6) {
                    ForEach(results.prefix(4)) { place in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(place.name).font(.brim(12.5))
                            Text(place.region).font(.brim(10.5, .bold)).foregroundStyle(theme.f(0.5)).lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .hoverFill(12, base: theme.f(0.07), hover: theme.f(0.13))
                        .onTapGesture {
                            weather.choose(place)
                            picking = false
                            query = ""
                            results = []
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                    }
                }
            }
        }
    }

    private func search() {
        let text = query
        guard text.count >= 2 else { results = []; return }
        Task {
            let found = await weather.search(text)
            if text == query { results = found }
        }
    }

    static func hour(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("j")
        return formatter.string(from: date)
    }

    static func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: date)
    }
}

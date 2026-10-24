import AppKit
import IslandCore
import IslandSystem
import SwiftUI
import UserNotifications

/// Everything the open island's tabs read from, created once by the app.
@MainActor
final class BrimHub: ObservableObject {
    let settings: AppSettings
    let model: UsageModel
    let notes = NotesStore()
    let links = LinksStore()
    let scratch = ScratchStore()
    let timers = TimerService()
    let stats = StatsService()
    let sounds = SoundsService()
    let music = NowPlaying()
    let calendar = CalendarReader()
    let weather = WeatherService(directory: LocalData.directory, persist: !AppSettings.isSnapshot)
    let screenTime = ScreenTimeTracker(directory: LocalData.directory, persist: !AppSettings.isSnapshot)
    let clipboard = ClipboardService()
    let shelf = ShelfService()
    let launcher = LauncherService()
    let analytics = AnalyticsService()
    let currency = CurrencyService()
    let closed = ClosedNotchState()
    /// The Connections group Settings should open on next time.
    var pendingGroup: ConnectionGroup?
    /// Whether macOS lets Brim post notifications (nil until known, or when running unbundled).
    @Published var notificationsAllowed: Bool?

    init(settings: AppSettings, model: UsageModel) {
        self.settings = settings
        self.model = model
        timers.settings = settings
        Notifier.status { [weak self] status in
            self?.notificationsAllowed = status.map { $0 == .authorized || $0 == .provisional }
        }
        defer { closed.start(self) }
        if AppSettings.isSnapshot {
            music.loadSample()
            calendar.loadSamples()
            weather.loadSample()
            screenTime.loadSample()
        }
    }

    /// Tabs with a working screen in this build.
    static let available: Set<TabID> = Set(TabID.allCases)

    /// A problem worth an orange dot on the tab, visible from any other tab.
    func hasWarning(_ tab: TabID) -> Bool {
        switch tab {
        case .ai: return AIAccounts(model: model, settings: settings).problemCount > 0
        case .calendar: return calendar.access == .denied
        case .home: return calendar.access == .denied || (music.track.map { music.denied.contains($0.player) } ?? false)
        case .weather: return weather.stale
        case .analytics: return analytics.current.map { analytics.errors[$0.id] != nil } ?? false
        default: return false
        }
    }

    /// The short note on the right of the header ("8 accounts", "Week of 19 Oct").
    func aside(for tab: TabID) -> String {
        switch tab {
        case .ai:
            let accounts = AIAccounts(model: model, settings: settings)
            guard !accounts.items.isEmpty else { return "" }
            let count = "\(accounts.items.count) account\(accounts.items.count == 1 ? "" : "s")"
            return accounts.problemCount > 0 ? "\(count) · \(accounts.problemCount) need attention" : count
        case .home:
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
            return formatter.string(from: Date())
        case .calendar:
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("d MMM")
            return calendar.access == .allowed ? "Week of " + formatter.string(from: Date()) : ""
        case .weather: return weather.forecast?.place ?? ""
        case .analytics: return analytics.current?.name ?? ""
        case .screen: return screenTime.enabled ? Clock.hm(screenTime.log.day(Date()).total) + " today" : ""
        case .clipboard: return clipboard.enabled ? "\(clipboard.items.count) items" : ""
        case .shelf: return shelf.files.isEmpty ? "" : "\(shelf.files.count) files"
        case .notes: return "\(notes.notes.count) note\(notes.notes.count == 1 ? "" : "s")"
        case .links: return "\(links.links.count) saved"
        case .sounds: return sounds.playing ? "\(sounds.levels.count) playing" : ""
        case .stats:
            return "\(ProcessInfo.processInfo.activeProcessorCount) cores · \(Bytes.format(Double(ProcessInfo.processInfo.physicalMemory)))"
        case .timers:
            let state = timers.state
            if state.pomodoroRunning { return "\(state.phase.title) · \(Clock.mmss(state.pomodoroRemaining(at: timers.now)))" }
            if state.countdownRunning { return "Countdown · \(Clock.mmss(state.countdownRemaining(at: timers.now)))" }
            if state.stopwatchRunning { return "Stopwatch · \(Clock.mmss(state.stopwatchElapsed(at: timers.now)))" }
            return ""
        default:
            return ""
        }
    }
}

/// The open island: header, tab bar and the selected tab.
struct IslandShellView: View {
    @ObservedObject var hub: BrimHub
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: UsageModel
    @ObservedObject var state: IslandState
    let openSettings: (SettingsSection) -> Void
    let addAccount: (AddAccountRequest) -> Void
    @State private var showMore = false
    @Environment(\.islandTheme) private var theme
    @Environment(\.tabPreset) private var preset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let contentHeight: CGFloat = 340

    private var layout: TabLayout {
        var layout = settings.tabLayout
        layout.order = layout.order.filter(BrimHub.available.contains)
        return layout
    }

    /// The selected tab, or the first visible one when the selection isn't available.
    private var tab: TabID {
        let selected = settings.selectedTab
        if BrimHub.available.contains(selected) { return selected }
        return layout.visible.first ?? .ai
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
                .padding(.horizontal, 12)
                .padding(.top, 4)
            content
                .frame(height: Self.contentHeight)
                .clipped()
                .padding(.top, 10)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .foregroundStyle(theme.fg)
        .overlay(alignment: .top) {
            if showMore {
                MoreTabsGrid(tabs: layout.order, current: tab) { picked in
                    settings.selectedTab = picked
                    showMore = false
                } close: { showMore = false } manage: {
                    showMore = false
                    openSettings(.tabs)
                }
                .padding(.top, headerHeight + 46)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: showMore)
        .onAppear { if preset["more"] != nil { showMore = true } }
    }

    private var headerHeight: CGFloat { max(37, state.barHeight) }

    /// Title on the left, note and gear on the right; nothing sits under the notch.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.symbol).font(.system(size: 14, weight: .semibold))
            Text(tab.title).font(.brim(14))
            Spacer(minLength: state.hasNotch ? state.notchWidth + 24 : 12)
            Text(hub.aside(for: tab))
                .font(.brim(11.5, .bold))
                .foregroundStyle(theme.f(0.45))
                .lineLimit(1)
            IconButton(symbol: "gearshape.fill", help: "Settings") { openSettings(.general) }
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .frame(height: headerHeight)
    }

    private var barTabs: [TabID] {
        var tabs = layout.visible
        // A tab picked from More shows in the bar while it's open.
        if !tabs.contains(tab) { tabs.append(tab) }
        return tabs
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(barTabs) { id in
                TabPill(tab: id, on: id == tab, warn: hub.hasWarning(id)) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { settings.selectedTab = id }
                }
            }
            if !layout.more.isEmpty {
                Rectangle().fill(theme.f(0.12)).frame(width: 1, height: 18).padding(.horizontal, 4)
                MorePill(on: showMore) { showMore.toggle() }
            }
        }
        .padding(3)
        .background(Capsule().fill(theme.f(0.06)))
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch tab {
            case .ai:
                AITabView(model: model, settings: settings, addAccount: addAccount,
                          manage: { openSettings(.connections) },
                          selected: preset["ai.selected"], adding: preset["ai.adding"] != nil)
            case .notes: NotesTabView(store: hub.notes)
            case .timers: TimersTabView(timers: hub.timers, sub: preset["timers.sub"])
            case .stats: StatsTabView(stats: hub.stats)
            case .links: LinksTabView(store: hub.links)
            case .sounds: SoundsTabView(sounds: hub.sounds)
            case .scratchpad: ScratchpadTabView(store: hub.scratch)
            case .units: UnitsTabView(currency: hub.currency, start: preset["units.category"])
            case .home:
                HomeTabView(hub: hub, music: hub.music, calendar: hub.calendar, launcher: hub.launcher, timers: hub.timers,
                            weather: hub.weather, model: model) { settings.selectedTab = $0 }
            case .calendar: CalendarTabView(calendar: hub.calendar, sub: preset["calendar.sub"])
            case .weather: WeatherTabView(weather: hub.weather)
            case .screen: ScreenTimeTabView(tracker: hub.screenTime, sub: preset["screen.sub"])
            case .clipboard: ClipboardTabView(clipboard: hub.clipboard)
            case .shelf: ShelfTabView(shelf: hub.shelf)
            case .files: FilesTabView()
            case .analytics:
                AnalyticsTabView(analytics: hub.analytics) {
                    hub.pendingGroup = .analytics
                    openSettings(.connections)
                }
            }
        }
        .id(tab)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// One tab in the bar: an icon, plus its name while selected.
struct TabPill: View {
    let tab: TabID
    let on: Bool
    var warn = false
    let pick: () -> Void
    @Environment(\.islandTheme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: tab.symbol).font(.system(size: 13.5, weight: .semibold))
            if on {
                Text(tab.title).font(.brim(12.5)).lineLimit(1).fixedSize()
            }
            if warn {
                Circle().fill(Palette.amber).frame(width: 6, height: 6).padding(.leading, -3)
            }
        }
        .padding(.leading, on ? 10 : 9)
        .padding(.trailing, on ? 13 : 9)
        .frame(height: 32)
        .foregroundStyle(on ? theme.bg : theme.f(0.7))
        .background(Capsule().fill(on ? theme.fg : hovering ? theme.f(0.1) : .clear))
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onTapGesture(perform: pick)
        .help(tab.title)
        .accessibilityElement()
        .accessibilityLabel(tab.title + (warn ? ", needs attention" : ""))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// Opens the grid of every tab.
struct MorePill: View {
    let on: Bool
    let action: () -> Void
    @Environment(\.islandTheme) private var theme
    @State private var hovering = false

    var body: some View {
        ZStack {
            Capsule().fill(on ? theme.fg : hovering ? theme.f(0.1) : .clear)
            Image(systemName: on ? "xmark" : "square.grid.3x3.fill")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundColor(on ? theme.bg : theme.f(0.7))
        }
            .frame(width: 34, height: 32)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .help("All tabs")
            .accessibilityLabel("All tabs")
            .accessibilityAddTraits(.isButton)
    }
}

/// Every tab as a tile, for the ones that don't fit in the bar.
struct MoreTabsGrid: View {
    let tabs: [TabID]
    let current: TabID
    let pick: (TabID) -> Void
    let close: () -> Void
    let manage: () -> Void
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(title: "All tabs")
                Button("Edit tabs…", action: manage)
                    .buttonStyle(.plain)
                    .font(.brim(11.5))
                    .foregroundStyle(theme.f(0.55))
            }
            .padding(.horizontal, 6)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                ForEach(tabs) { id in
                    VStack(spacing: 6) {
                        Image(systemName: id.symbol).font(.system(size: 16, weight: .semibold))
                        Text(id.title).font(.brim(11, .bold)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 62)
                    .foregroundStyle(id == current ? theme.bg : theme.fg)
                    .hoverFill(14, base: id == current ? theme.fg : theme.f(0.06), hover: id == current ? theme.fg : theme.f(0.13))
                    .onTapGesture { pick(id) }
                    .accessibilityLabel(id.title)
                    .accessibilityAddTraits(.isButton)
                }
            }
        }
        .padding(10)
        .frame(width: 560)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(theme.pop))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.f(0.1)))
        .shadow(color: .black.opacity(0.45), radius: 20, y: 14)
        .onExitCommand(perform: close)
    }
}

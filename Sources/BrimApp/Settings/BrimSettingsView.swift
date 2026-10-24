import AppKit
import IslandCore
import IslandServices
import ServiceManagement
import SwiftUI

/// Pages of the Settings window, opened from the island's gear.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case tabs
    case notch
    case connections
    case perms
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .tabs: return "Tabs"
        case .notch: return "Closed notch"
        case .connections: return "Connections"
        case .perms: return "Permissions"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .tabs: return "rectangle.split.3x1"
        case .notch: return "rectangle.topthird.inset.filled"
        case .connections: return "link"
        case .perms: return "checkmark.shield"
        case .about: return "info.circle"
        }
    }
}

/// Which group of accounts Settings › Connections shows.
enum ConnectionGroup: String, CaseIterable, Identifiable {
    case ai, music, calendar, analytics, weather
    var id: String { rawValue }
    var title: String { self == .ai ? "AI" : rawValue.capitalized }
}

/// The Settings window: General, Tabs, Closed notch, Connections, Permissions and About.
struct BrimSettingsView: View {
    @ObservedObject var hub: BrimHub
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: UsageModel
    @State var section: SettingsSection
    @State var group: ConnectionGroup = .ai
    @State private var adding: AddAccountRequest?

    private var theme: IslandTheme { IslandTheme.resolve(settings.appearance) }
    private var windowFill: Color { theme.isDark ? Color(red: 0x1E / 255, green: 0x1E / 255, blue: 0x20 / 255) : .white }
    private var sideFill: Color { theme.isDark ? Color(red: 0x16 / 255, green: 0x16 / 255, blue: 0x18 / 255) : Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF5 / 255) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
                .background(sideFill)
            VStack(alignment: .leading, spacing: 0) {
                Text(section.title)
                    .font(.brim(18))
                    .padding(.horizontal, 28)
                    .frame(height: 56, alignment: .center)
                Rectangle().fill(theme.f(0.07)).frame(height: 1)
                IslandScroll {
                    page
                        .padding(.horizontal, 24)
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .background(windowFill)
        }
        .foregroundStyle(theme.fg)
        .environment(\.islandTheme, theme)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .frame(minWidth: 820, minHeight: 540)
        .ignoresSafeArea()
        .sheet(item: $adding) { request in
            AddAccountView(model: model, settings: settings, request: request) { adding = nil }
                .frame(width: 520, height: 640)
        }
    }

    // MARK: Sidebar

    private var problemCount: Int { AIAccounts(model: model, settings: settings).problemCount }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 48)
            ForEach(SettingsSection.allCases) { item in
                let on = item == section
                HStack(spacing: 9) {
                    Image(systemName: item.symbol).font(.system(size: 12.5, weight: .semibold)).frame(width: 18)
                    Text(item.title).font(.brim(13, .bold))
                    Spacer()
                    if item == .connections, problemCount > 0 {
                        Text("\(problemCount)")
                            .font(.brim(10.5))
                            .foregroundStyle(.black)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Circle().fill(Palette.amber))
                    }
                }
                .foregroundStyle(on ? theme.fg : theme.f(0.75))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .hoverFill(8, base: on ? theme.f(0.12) : .clear, hover: on ? theme.f(0.12) : theme.f(0.08))
                .onTapGesture { section = item }
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
            Spacer()
            Text("Brim \(BrimVersion.string)")
                .font(.brim(11, .bold))
                .foregroundStyle(theme.f(0.4))
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private var page: some View {
        switch section {
        case .general: GeneralPage(settings: settings)
        case .tabs: TabsPage(hub: hub, settings: settings)
        case .notch: NotchPage(settings: settings)
        case .connections:
            ConnectionsPage(hub: hub, settings: settings, model: model, group: $group) { adding = $0 }
        case .perms: PermissionsPage(hub: hub)
        case .about: AboutPage(settings: settings, updates: hub.updates)
        }
    }
}

// MARK: - Building blocks

/// A rounded group of rows with hairlines between them.
struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { SectionTitle(title: title, opacity: 0.5).padding(.horizontal, 4) }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.f(0.05)))
        }
    }
}

/// One row: label and optional line under it on the left, a control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var sub: String?
    var divider = true
    @ViewBuilder var control: Control
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.brim(13, .bold))
                if let sub {
                    Text(sub).font(.brim(11.5, .medium)).foregroundStyle(theme.f(0.5)).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .top) {
            if divider { Rectangle().fill(theme.f(0.07)).frame(height: 1) }
        }
    }
}

/// A status capsule: Connected, Needs attention, Not connected, Allowed, Denied.
struct StatusPill: View {
    enum Kind { case ok, warn, off, denied }
    let text: String
    let kind: Kind
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let (bg, fg): (Color, Color) = {
            switch kind {
            case .ok: return (Palette.green.opacity(0.14), Palette.green)
            case .warn: return (Palette.amber.opacity(0.16), Palette.amber)
            case .off: return (theme.f(0.08), theme.f(0.55))
            case .denied: return (Palette.red.opacity(0.14), Palette.red)
            }
        }()
        Text(text)
            .font(.brim(11))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .foregroundStyle(fg)
            .background(Capsule().fill(bg))
            .fixedSize()
    }
}

// MARK: - General

struct GeneralPage: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var cliMessage: String?
    @State private var cliFix: CommandLineTool.Fix?
    @State private var error: String?
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup {
                SettingsRow(title: "Launch at login", divider: false) {
                    IslandSwitch(isOn: Binding(get: { launchAtLogin }, set: setLaunch), label: "Launch at login")
                }
                SettingsRow(title: "Open the island", sub: "Hover waits 120 ms, so passing the cursor over the notch does nothing") {
                    SegmentedPills(options: [(true, "Hover"), (false, "Click")], selection: $settings.expandOnHover, look: .strong, height: 24)
                }
                SettingsRow(title: "Show on") {
                    SegmentedPills(options: IslandDisplay.allCases.map { ($0, $0.title) }, selection: $settings.display, look: .strong, height: 24)
                }
                SettingsRow(title: "Appearance", sub: "The closed notch stays black in both") {
                    SegmentedPills(options: IslandAppearance.allCases.map { ($0, $0.title) }, selection: $settings.appearance, look: .strong, height: 24)
                }
                SettingsRow(title: "Open with keyboard", sub: "Press ⌥ Space anywhere to open or close the island") {
                    HStack(spacing: 8) {
                        Key("⌥")
                        Key("Space")
                        IslandSwitch(isOn: $settings.hotkeyEnabled, label: "Keyboard shortcut")
                    }
                }
            }

            SettingsGroup(title: "Island") {
                SettingsRow(title: "Show the island", divider: false) {
                    IslandSwitch(isOn: $settings.showIsland, label: "Show the island")
                }
                SettingsRow(title: "Placement", sub: settings.placementMovedForCrowding ? "Moved below the menu bar: other status icons left too little room next to the notch." : nil) {
                    SegmentedPills(options: [(IslandPlacement.wrapNotch, "Notch"), (.belowMenuBar, "Below menu bar"), (.menuBarOnly, "Menu bar only")],
                                   selection: $settings.placement, look: .strong, height: 24)
                }
                SettingsRow(title: "When another app uses the notch") {
                    SegmentedPills(options: NotchConflictPolicy.allCases.map { ($0, $0.title) }, selection: $settings.notchConflict, look: .strong, height: 24)
                }
                SettingsRow(title: "Hide in full-screen apps") {
                    IslandSwitch(isOn: $settings.hideInFullScreen, label: "Hide in full-screen apps")
                }
                SettingsRow(title: "Playful animations", sub: "Confetti, bouncing icons and rolling numbers") {
                    IslandSwitch(isOn: $settings.playful, label: "Playful animations")
                }
            }

            SettingsGroup(title: "AI usage") {
                SettingsRow(title: "Read logs every", divider: false) {
                    SegmentedPills(options: [(5.0, "5s"), (10.0, "10s"), (30.0, "30s"), (60.0, "1m")], selection: $settings.refreshSeconds, look: .strong, height: 24)
                }
                SettingsRow(title: "Show account emails", sub: "Turn off while sharing your screen") {
                    IslandSwitch(isOn: $settings.showAccountEmails, label: "Show account emails")
                }
                SettingsRow(title: "Closed notch shows") {
                    SegmentedPills(options: [(CompactMetric.auto, "Automatic"), (.tokens, "Tokens"), (.plan, "Plan %")],
                                   selection: $settings.compactMetric, look: .strong, height: 24)
                }
                SettingsRow(title: "brim command", sub: cliMessage ?? "Optional. Lets you run brim status in Terminal.") {
                    if let cliFix {
                        IslandButton(title: cliFix.title, height: 26) { (cliMessage, self.cliFix) = cliFix.run() }
                    } else {
                        IslandButton(title: "Install", height: 26) { (cliMessage, cliFix) = CommandLineTool.install() }
                    }
                }
            }
            if let error {
                Text(error).font(.brim(12, .bold)).foregroundStyle(Palette.red)
            }
        }
    }

    private func setLaunch(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// A keycap.
struct Key: View {
    let label: String
    init(_ label: String) { self.label = label }
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Text(label)
            .font(.brim(11.5))
            .padding(.horizontal, 8)
            .frame(minWidth: 26, minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.f(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.f(0.12)))
    }
}

// MARK: - Tabs

struct TabsPage: View {
    @ObservedObject var hub: BrimHub
    @ObservedObject var settings: AppSettings
    @Environment(\.islandTheme) private var theme

    private var order: [TabID] { settings.tabLayout.order.filter(BrimHub.available.contains) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reorder the tab bar and choose which tabs show. Hidden tabs stay one click away under the grid button.")
                .font(.brim(12.5, .medium))
                .foregroundStyle(theme.f(0.6))
            SettingsGroup {
                ForEach(Array(order.enumerated()), id: \.element) { index, id in
                    let visible = settings.tabLayout.isVisible(id)
                    HStack(spacing: 12) {
                        Image(systemName: id.symbol).font(.system(size: 13, weight: .semibold)).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(id.title).font(.brim(13, .bold))
                            Text(hub.hasWarning(id) ? "Needs attention" : id.blurb)
                                .font(.brim(11.5, .medium))
                                .foregroundStyle(hub.hasWarning(id) ? Palette.amber : theme.f(0.5))
                        }
                        Spacer()
                        arrow("chevron.up", enabled: index > 0) { settings.tabLayout.move(id, by: -1) }
                        arrow("chevron.down", enabled: index < order.count - 1) { settings.tabLayout.move(id, by: 1) }
                        IslandSwitch(isOn: Binding(get: { visible }, set: { settings.tabLayout.setVisible(id, $0) }), label: "Show \(id.title)")
                    }
                    .opacity(visible ? 1 : 0.55)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .overlay(alignment: .top) {
                        if index > 0 { Rectangle().fill(theme.f(0.07)).frame(height: 1) }
                    }
                }
            }
            HStack {
                Spacer()
                IslandButton(title: "Reset to default", height: 26) { settings.tabLayout = .standard }
            }
        }
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .frame(width: 24, height: 24)
            .opacity(enabled ? 0.75 : 0.2)
            .hoverFill(12, hover: enabled ? theme.f(0.1) : .clear)
            .onTapGesture { if enabled { action() } }
            .accessibilityLabel(symbol == "chevron.up" ? "Move up" : "Move down")
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Closed notch

struct NotchPage: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(title: "Rotates through") {
                SettingsRow(title: "Now playing", sub: "Song and time left", divider: false) {
                    IslandSwitch(isOn: $settings.closedMusic, label: "Now playing")
                }
                SettingsRow(title: "Timer countdown", sub: "Takes over while a timer runs") {
                    IslandSwitch(isOn: $settings.closedTimer, label: "Timer countdown")
                }
                SettingsRow(title: "AI limits", sub: "Two accounts at a time, highest usage first") {
                    IslandSwitch(isOn: $settings.closedAI, label: "AI limits")
                }
            }
            SettingsGroup(title: "Interrupts with") {
                SettingsRow(title: "Limit warnings", sub: "At 80% and 95% of a 5h or weekly limit", divider: false) {
                    IslandSwitch(isOn: $settings.interruptLimits, label: "Limit warnings")
                }
                SettingsRow(title: "Account problems", sub: "Signed out, missing logs, revoked keys") {
                    IslandSwitch(isOn: $settings.interruptAccounts, label: "Account problems")
                }
                SettingsRow(title: "Timer finished", sub: "Pomodoro and countdown") {
                    IslandSwitch(isOn: $settings.interruptTimerDone, label: "Timer finished")
                }
                SettingsRow(title: "Event starting", sub: "5 minutes before, with a Join button") {
                    IslandSwitch(isOn: $settings.interruptEvents, label: "Event starting")
                }
            }
        }
    }
}

// MARK: - Connections

struct ConnectionsPage: View {
    @ObservedObject var hub: BrimHub
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: UsageModel
    @Binding var group: ConnectionGroup
    let add: (AddAccountRequest) -> Void
    @State private var open: String?
    @State private var renaming: String?
    @State private var labelDraft = ""
    @State private var confirmRemove: Connection?
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SegmentedPills(options: ConnectionGroup.allCases.map { ($0, $0.title) }, selection: $group,
                           dot: { $0 == .ai && AIAccounts(model: model, settings: settings).problemCount > 0 ? Palette.amber : nil })
            switch group {
            case .ai: aiPage
            default: hub.connectionsPage(group)
            }
        }
        .confirmationDialog("Remove \(confirmRemove?.name ?? "")?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove", role: .destructive) {
                if let id = confirmRemove?.id { model.remove(id) }
                confirmRemove = nil
            }
        } message: {
            Text("Its settings and saved token are deleted. You can add it again any time.")
        }
    }

    private var aiPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text("Each account gets its own pill inside AI. Claude and Codex read token counts from local logs; signing in adds plan limits. Labels tell accounts of the same tool apart.")
                    .font(.brim(12.5, .medium))
                    .foregroundStyle(theme.f(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                IslandButton(title: "Add AI account", style: .primary, height: 28, symbol: "plus") { add(AddAccountRequest()) }
            }
            if settings.connections.isEmpty {
                SettingsGroup {
                    Text("Nothing connected yet. Add Claude, Codex, Cursor, Copilot or any other tool.")
                        .font(.brim(12.5, .medium))
                        .foregroundStyle(theme.f(0.6))
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                SettingsGroup {
                    ForEach(Array(settings.connections.enumerated()), id: \.element.id) { index, connection in
                        aiRow(connection, divider: index > 0)
                    }
                }
            }
            HStack {
                Text("Tokens and keys stay in your macOS Keychain. The same Claude email can't be added twice.")
                    .font(.brim(11.5, .medium))
                    .foregroundStyle(theme.f(0.45))
                Spacer()
                if settings.enabledConnections.isEmpty {
                    IslandButton(title: "Connect all", height: 24, fontSize: 11.5) { model.connectAll() }
                } else {
                    IslandButton(title: "Disconnect all", height: 24, fontSize: 11.5) { model.disconnectAll() }
                }
            }
        }
    }

    private func status(_ connection: Connection) -> (String, StatusPill.Kind, AIProblem?) {
        guard connection.isEnabled else { return ("Not connected", .off, nil) }
        switch model.states[connection.id] ?? .checking {
        case .attention(let message) where model.snapshot[connection.id]?.hasData != true:
            return ("Needs attention", .warn, AIProblem(message: message))
        case .checking: return ("Connecting…", .off, nil)
        default: return ("Connected", .ok, nil)
        }
    }

    private func subline(_ connection: Connection) -> String {
        var parts: [String] = []
        let tool = model.snapshot[connection.id]
        if let plan = tool?.planName { parts.append(plan) }
        if case .attention(let message) = model.states[connection.id], tool?.hasData != true {
            parts.append(message)
        } else {
            switch connection.kind {
            case .claude, .codex, .customLogs:
                parts.append(connection.logSource()?.roots.first.map { Self.tilde($0.path) } ?? "local logs")
            case .openrouter: parts.append("API key")
            default: parts.append("signed in")
            }
            if let email = model.accountLabel(for: connection.id) { parts.append(email) }
        }
        return parts.joined(separator: " · ")
    }

    static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func aiRow(_ connection: Connection, divider: Bool) -> some View {
        let (text, kind, problem) = status(connection)
        let isOpen = open == connection.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ToolGlyph(kind: connection.kind, mood: kind == .warn ? .dim : .idle, size: 20, playful: false, name: connection.name)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(AccountTag.split(connection.name).base).font(.brim(13, .bold))
                        if let tag = connection.tag {
                            Text(tag)
                                .font(.brim(10.5))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 5).fill(theme.f(0.1)))
                                .foregroundStyle(theme.f(0.6))
                        }
                        if connection.kind.isExperimental {
                            Text("experimental").font(.brim(10, .bold)).foregroundStyle(theme.f(0.4))
                        }
                    }
                    Text(subline(connection))
                        .font(.brim(11.5, .medium))
                        .foregroundStyle(theme.f(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 10)
                StatusPill(text: text, kind: kind)
                if let problem {
                    IslandButton(title: problem.short == "Sign in" ? "Sign in" : problem.button, style: .tint(Palette.amber), height: 26, fontSize: 11.5) {
                        fix(connection, problem)
                    }
                } else if !connection.isEnabled {
                    IslandButton(title: "Connect", style: .primary, height: 26, fontSize: 11.5) { model.connect(connection.id) }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.f(0.4))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { open = isOpen ? nil : connection.id } }

            if isOpen {
                details(connection)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if divider { Rectangle().fill(theme.f(0.07)).frame(height: 1) }
        }
    }

    private func details(_ connection: Connection) -> some View {
        let tool = model.snapshot[connection.id]
        return VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                if let root = connection.logSource()?.roots.first {
                    DetailRow(key: "Token source", value: Self.tilde(root.path), height: 26)
                }
                if let windows = tool?.planWindows, !windows.isEmpty {
                    DetailRow(key: "Plan limits", value: Format.allUsed(windows, kind: connection.kind), height: 26)
                }
                DetailRow(key: "Last sync", value: tool?.updatedAt.map { Format.ago($0) } ?? model.states[connection.id]?.summary ?? "–", height: 26)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.f(0.05)))

            if renaming == connection.id {
                HStack(spacing: 8) {
                    TextField("Label, e.g. work", text: $labelDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onSubmit { saveLabel(connection) }
                    IslandButton(title: "Save", style: .primary, height: 26, fontSize: 11.5) { saveLabel(connection) }
                    IslandButton(title: "Cancel", height: 26, fontSize: 11.5) { renaming = nil }
                }
            }

            HStack(spacing: 8) {
                IslandButton(title: "Refresh now", height: 26, fontSize: 11.5) { model.connect(connection.id) }
                IslandButton(title: "Rename label", height: 26, fontSize: 11.5) {
                    labelDraft = connection.tag ?? ""
                    renaming = connection.id
                }
                if connection.kind.source == .account || connection.kind == .claude {
                    IslandButton(title: "Sign in again", height: 26, fontSize: 11.5) { add(AddAccountRequest(connectionID: connection.id)) }
                }
                if connection.isEnabled {
                    IslandButton(title: "Disconnect", height: 26, fontSize: 11.5) { model.disconnect(connection.id) }
                }
                Spacer()
                IslandButton(title: "Remove", style: .destructive, height: 26, fontSize: 11.5) { confirmRemove = connection }
            }

            DisclosureGroup("Advanced") {
                ConnectionRow(connection: binding(connection), model: model,
                              signIn: { add(AddAccountRequest(connectionID: connection.id)) },
                              isExpanded: .constant(true), showsHeader: false)
                    .padding(.top, 6)
            }
            .font(.brim(12, .bold))
        }
    }

    private func binding(_ connection: Connection) -> Binding<Connection> {
        Binding(get: { settings.connection(connection.id) ?? connection }, set: { settings.update($0) })
    }

    private func saveLabel(_ connection: Connection) {
        var updated = settings.connection(connection.id) ?? connection
        updated.setTag(labelDraft)
        settings.update(updated)
        renaming = nil
    }

    private func fix(_ connection: Connection, _ problem: AIProblem) {
        switch problem {
        case .signedOut: add(AddAccountRequest(connectionID: connection.id))
        case .logsMissing:
            FolderPicker.choose(message: "Choose the folder \(connection.name) writes its logs to") { url in
                var updated = connection
                updated.options[connection.kind == .claude ? Connection.Option.configDir : Connection.Option.path] = url.path
                settings.update(updated)
            }
        default: model.connect(connection.id)
        }
    }
}

// MARK: - Permissions

struct PermissionsPage: View {
    @ObservedObject var hub: BrimHub
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What macOS has allowed Brim to use. Brim asks only when you turn on a tab that needs it.")
                .font(.brim(12.5, .medium))
                .foregroundStyle(theme.f(0.6))
            SettingsGroup {
                ForEach(Array(hub.permissions().enumerated()), id: \.offset) { index, permission in
                    SettingsRow(title: permission.title, sub: permission.detail, divider: index > 0) {
                        HStack(spacing: 8) {
                            StatusPill(text: permission.state.title, kind: permission.state.pill)
                            if let action = permission.action {
                                IslandButton(title: permission.state == .denied ? "Open System Settings" : "Allow",
                                             style: permission.state == .denied ? .secondary : .primary,
                                             height: 26, fontSize: 11.5, action: action)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One macOS permission as Settings › Permissions shows it.
struct PermissionInfo {
    enum State {
        case allowed, notAsked, denied
        var title: String {
            switch self {
            case .allowed: return "Allowed"
            case .notAsked: return "Not asked"
            case .denied: return "Denied"
            }
        }
        var pill: StatusPill.Kind {
            switch self {
            case .allowed: return .ok
            case .notAsked: return .off
            case .denied: return .denied
            }
        }
    }

    let title: String
    let detail: String
    let state: State
    var action: (() -> Void)?
}

// MARK: - About

struct AboutPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var updates: UpdateWatcher
    @State private var copied = false
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 56, height: 56)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Brim").font(.brim(20))
                    Text("Version \(BrimVersion.string) · a living notch for your Mac")
                        .font(.brim(12.5, .medium))
                        .foregroundStyle(theme.f(0.55))
                }
            }
            SettingsGroup {
                if let update = updates.available {
                    SettingsRow(title: "Brim \(update.version) is available", sub: "You have \(BrimVersion.string). Brim quits, installs and reopens.", divider: false) {
                        IslandButton(title: "Update", style: .tint(Palette.green), height: 26, fontSize: 11.5) {
                            BrimUpdateUI.offer(update, watcher: updates)
                        }
                    }
                }
                SettingsRow(title: "Check for updates automatically", sub: lastCheckText, divider: updates.available != nil) {
                    IslandSwitch(isOn: $settings.autoCheckUpdates, label: "Check for updates automatically")
                }
                SettingsRow(title: "Check for updates", sub: "From GitHub Releases") {
                    IslandButton(title: "Check now", height: 26, fontSize: 11.5) {
                        Task { @MainActor in await BrimUpdateUI.check(from: nil) }
                    }
                }
                SettingsRow(title: "Source code", sub: "github.com/abhargava14/brim") {
                    IslandButton(title: "Open", height: 26, fontSize: 11.5) {
                        NSWorkspace.shared.open(URL(string: "https://github.com/abhargava14/brim")!)
                    }
                }
                SettingsRow(title: "Report a problem", sub: "Opens a GitHub issue you can review before sending") {
                    IslandButton(title: "Report", height: 26, fontSize: 11.5) {
                        NSWorkspace.shared.open(URL(string: "https://github.com/abhargava14/brim/issues/new")!)
                    }
                }
                SettingsRow(title: "Diagnostics", sub: "Copies versions and which tools are connected. No tokens, keys or emails.") {
                    IslandButton(title: copied ? "Copied" : "Copy", height: 26, fontSize: 11.5) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnostics, forType: .string)
                        copied = true
                    }
                }
            }
            Text("Brim is free and open source. No account, no tracking. Your prompts and code are never read.")
                .font(.brim(11.5, .medium))
                .foregroundStyle(theme.f(0.45))
        }
    }

    private var lastCheckText: String {
        guard let date = updates.lastCheck else { return "Once a day, from GitHub Releases" }
        return "Once a day · last checked " + Format.ago(date)
    }

    private var diagnostics: String {
        let kinds = Dictionary(grouping: settings.connections, by: \.kind).map { "\($0.key.rawValue)×\($0.value.count)" }.sorted()
        return """
        Brim \(BrimVersion.string)
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Connections: \(kinds.joined(separator: ", "))
        Visible tabs: \(settings.tabLayout.visible.map(\.rawValue).joined(separator: ", "))
        """
    }
}

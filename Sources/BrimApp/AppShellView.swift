import AppKit
import IslandCore
import IslandServices
import ServiceManagement
import SwiftUI

/// Primary Brim app window: dark sidebar + page content (Overview / Connections / Island / Settings).
/// Replaces the old tabbed preferences sheet. Chrome matches the island / Add Connection aesthetic.
struct AppShellView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var settings: AppSettings
    @State private var page: AppPage = ProcessInfo.processInfo.environment["BRIM_OPEN_ISLAND"] == "1" ? .island : .overview
    @State private var errorMessage: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var cliMessage: String?
    @State private var expanded: String?
    @State private var cliFix: CommandLineTool.Fix?
    @State private var adding: AddAccountRequest?

    private enum AppPage: String, CaseIterable, Identifiable {
        case overview
        case connections
        case island
        case general

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "Overview"
            case .connections: return "Connections"
            case .island: return "Island"
            case .general: return "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .overview: return "square.grid.2x2"
            case .connections: return "link"
            case .island: return "rectangle.roundedtop"
            case .general: return "gearshape"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
            Rectangle()
                .fill(BrimChrome.hairline)
                .frame(width: 1)
            main
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(BrimChrome.canvas)
        .preferredColorScheme(.dark)
        .frame(minWidth: 860, minHeight: 560)
        .sheet(item: $adding) { request in
            AddAccountView(model: model, settings: settings, request: request) { adding = nil }
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: BrimAssets.brimMenuMark ?? NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Brim")!)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 22, height: 22)
                Text("Brim")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(BrimChrome.ink)
                Spacer()
                Text("v\(BrimVersion.string)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(BrimChrome.muted)
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 22)

            VStack(spacing: 4) {
                ForEach(AppPage.allCases) { item in
                    sidebarRow(item)
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    adding = AddAccountRequest()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 16, alignment: .center)
                        Text("Add Account…")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Capsule().fill(BrimChrome.ctaFill))
                    .foregroundStyle(BrimChrome.ctaLabel)
                    .contentShape(Capsule())
                }
                .buttonStyle(AppShellNavButtonStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Capsule())
                .onHover(perform: AppShellPointer.hand)

                Text("Plan limits show how much is used.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(BrimChrome.muted)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 20)
        }
        .background(BrimChrome.sidebar)
    }

    /// Full-row nav control: icon + padding + background share one hit target and pointer cursor.
    /// `Label` alone still routes hits/cursor to the title string on macOS plain buttons.
    private func sidebarRow(_ item: AppPage) -> some View {
        let selected = page == item
        return Button {
            page = item
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .frame(width: 16, alignment: .center)
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium, design: .rounded))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    // Near-clear (not Color.clear) so the padded row stays in the hit tree.
                    .fill(selected ? BrimChrome.selected : Color.white.opacity(0.001))
            )
            .foregroundStyle(selected ? BrimChrome.ink : BrimChrome.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(AppShellNavButtonStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover(perform: AppShellPointer.hand)
    }

    // MARK: Main

    @ViewBuilder
    private var main: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(page.title)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(BrimChrome.ink)
                    .padding(.bottom, 4)

                switch page {
                case .overview: overviewPage
                case .connections: connectionsPage
                case .island: islandPage
                case .general: generalPage
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(BrimChrome.canvas)
    }

    // MARK: Overview

    private var overviewPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppShellCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Today")
                        .font(BrimChrome.section)
                        .foregroundStyle(BrimChrome.muted)
                    Text(model.snapshot.usageTodayHeadline)
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(BrimChrome.ink)
                    Text("\(settings.enabledConnections.count) connected")
                        .font(BrimChrome.body)
                        .foregroundStyle(BrimChrome.muted)
                }
            }

            if model.featuredTools.isEmpty {
                AppShellCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            ForEach([ToolKind.claude, .codex, .copilot, .cursor, .windsurf, .openrouter]) { kind in
                                ToolGlyph(kind: kind, mood: .dim, size: 14, playful: false)
                                    .frame(width: 28, height: 28)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
                            }
                        }
                        Text("Connect your AIs")
                            .font(BrimChrome.headline)
                        Text("See tokens and plan limits for each tool in the notch.")
                            .font(BrimChrome.body)
                            .foregroundStyle(BrimChrome.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        BrimChrome.primaryButton("Add Account…") { adding = AddAccountRequest() }
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    ForEach(model.featuredTools) { tool in
                        overviewToolCard(tool)
                    }
                }
            }
        }
    }

    private func overviewToolCard(_ tool: ToolSnapshot) -> some View {
        let err = tool.statusMessage != nil && !tool.hasData
        let windows = tool.displayPlanWindows
        return AppShellCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ToolGlyph(kind: tool.kind, mood: err ? .dim : .idle, size: 15, playful: false, name: tool.name)
                    Text(tool.name)
                        .font(BrimChrome.headline)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if model.isWorking(tool) {
                        Circle().fill(tool.kind.tint).frame(width: 6, height: 6)
                    }
                }
                if let account = model.accountLabel(for: tool.id) {
                    Text(account)
                        .font(BrimChrome.caption)
                        .foregroundStyle(BrimChrome.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if err {
                    Text(tool.statusMessage ?? "Signed out")
                        .font(BrimChrome.body)
                        .foregroundStyle(Color.orange)
                } else if !windows.isEmpty {
                    // Every window — Cursor dual pools, Claude Fable + Week · all models, etc.
                    PlanWindowsList(windows: windows, kind: tool.kind, style: .app, showBars: true)
                } else if tool.hasData {
                    Text(model.compactValue(for: tool))
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(BrimChrome.ink)
                    if tool.hasTokenData {
                        Text("tokens today")
                            .font(BrimChrome.caption)
                            .foregroundStyle(BrimChrome.muted)
                    }
                } else {
                    Text(tool.statusMessage ?? "Connecting…")
                        .font(BrimChrome.caption)
                        .foregroundStyle(BrimChrome.muted)
                }
            }
        }
    }

    // MARK: Connections

    private var connectionsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppShellCard {
                VStack(alignment: .leading, spacing: 12) {
                    if settings.connections.isEmpty {
                        Text("Nothing connected yet. Add Claude, Codex, Cursor, Copilot or any other tool.")
                            .font(BrimChrome.body)
                            .foregroundStyle(BrimChrome.muted)
                    }
                    ForEach($settings.connections) { $connection in
                        ConnectionRow(
                            connection: $connection,
                            model: model,
                            signIn: { adding = AddAccountRequest(connectionID: connection.id) },
                            isExpanded: Binding(get: { expanded == connection.id }, set: { expanded = $0 ? connection.id : nil })
                        )
                    }
                    .onMove { settings.move(from: $0, to: $1) }

                    HStack {
                        Button { adding = AddAccountRequest() } label: {
                            Label("Add Account…", systemImage: "plus")
                        }
                        Spacer()
                        if settings.enabledConnections.isEmpty {
                            Button("Connect all") { model.connectAll() }
                                .disabled(settings.connections.isEmpty)
                        } else {
                            Button("Disconnect all") { model.disconnectAll() }
                        }
                    }
                }
            }

            AppShellCard {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Claude plan limits")
                            .font(BrimChrome.headline)
                        Text(claudeStatusText)
                            .font(BrimChrome.caption)
                            .foregroundStyle(BrimChrome.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if model.claudeConnection == .connected {
                        Button("Disconnect") { run { try model.disconnectClaudePlan() } }
                    } else {
                        Button("Connect") { run { try model.connectClaudePlan() } }
                            .disabled(model.claudeConnection == .unreadable)
                    }
                }
            }

            Text("Tokens stay in your Keychain. The same email can’t be added twice.")
                .font(BrimChrome.caption)
                .foregroundStyle(BrimChrome.muted)
        }
    }

    private var claudeStatusText: String {
        switch model.claudeConnection {
        case .connected:
            return "Optional status-line bridge connected for Claude Code session hints."
        case .notConnected:
            return "Optional. Adds a small status line script to Claude Code. Plan limits from Sign in with Claude do not need this."
        case .unreadable:
            return "~/.claude/settings.json could not be read. Fix the file, then try again."
        }
    }

    // MARK: Island

    private var islandPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppShellCard {
                Form {
                    Toggle("Show the island at the top of the screen", isOn: $settings.showIsland)
                    Picker("Show in", selection: $settings.placement) {
                        ForEach(IslandPlacement.allCases) { placement in
                            Text(placement.title).tag(placement)
                        }
                    }
                    if settings.placementMovedForCrowding {
                        Text("Moved below the menu bar — other status icons left too little room next to the notch. Choose “Around the notch” to try again.")
                            .font(BrimChrome.caption)
                            .foregroundStyle(BrimChrome.muted)
                    }
                    Picker("With nothing connected", selection: $settings.emptyIsland) {
                        ForEach(EmptyIsland.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Picker("When another app uses the notch", selection: $settings.notchConflict) {
                        ForEach(NotchConflictPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    if settings.useNotchAnyway {
                        HStack {
                            Text("Using the notch even though another app is there.")
                                .font(BrimChrome.caption)
                                .foregroundStyle(BrimChrome.muted)
                            Spacer()
                            Button("Stop overriding") { settings.useNotchAnyway = false }
                                .controlSize(.small)
                        }
                    }
                    Toggle("Hide in full-screen apps", isOn: $settings.hideInFullScreen)
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }

            AppShellCard {
                Form {
                    Section("Expanded layout") {
                        Picker("Connections", selection: $settings.expandedLayout) {
                            ForEach(ExpandedLayout.allCases) { layout in
                                Text(layout.title).tag(layout)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(settings.expandedLayout.detail)
                            .font(BrimChrome.caption)
                            .foregroundStyle(BrimChrome.muted)
                    }
                    Section("Compact island") {
                        Toggle("Expand when the pointer is over it", isOn: $settings.expandOnHover)
                        Toggle("Playful animations (confetti, bouncing icons)", isOn: $settings.playful)
                        Picker("Compact view shows", selection: $settings.compactMetric) {
                            ForEach(CompactMetric.allCases) { metric in
                                Text(metric.title).tag(metric)
                            }
                        }
                        Picker("Claude cards open in", selection: $settings.claudeCardStyle) {
                            ForEach(ClaudeCardStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        Picker("Always feature", selection: $settings.pinnedID) {
                            Text("Automatic (most urgent first)").tag("")
                            ForEach(settings.connections) { connection in
                                Text(connection.name).tag(connection.id)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }

            Text("Compact pairs take turns every 4s. Expand for Cards or Strip detail.")
                .font(BrimChrome.caption)
                .foregroundStyle(BrimChrome.muted)
        }
    }

    // MARK: General / Settings

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppShellCard {
                Form {
                    Section("General") {
                        Picker("Read logs every", selection: $settings.refreshSeconds) {
                            Text("5 seconds").tag(5.0)
                            Text("10 seconds").tag(10.0)
                            Text("30 seconds").tag(30.0)
                            Text("1 minute").tag(60.0)
                        }
                        Toggle("Show account emails", isOn: $settings.showAccountEmails)
                            .help("Turn off while sharing your screen.")
                        Toggle("Launch at login", isOn: $launchAtLogin)
                            .onChange(of: launchAtLogin) { enabled in
                                guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
                                run {
                                    if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                                }
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }

            AppShellCard {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("brim command")
                            .font(BrimChrome.headline)
                        Text(cliMessage ?? "Optional. Installs into ~/.local/bin when possible — no Mac password. Lets you run brim status in Terminal.")
                            .font(BrimChrome.caption)
                            .foregroundStyle(BrimChrome.muted)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if let cliFix {
                        Button(cliFix.title) { (cliMessage, self.cliFix) = cliFix.run() }
                    } else {
                        Button("Install") { (cliMessage, cliFix) = CommandLineTool.install() }
                    }
                }
            }

            AppShellCard {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Updates")
                            .font(BrimChrome.headline)
                        Text("Check GitHub Releases for a newer Brim. Quit/reopen alone is not an update path.")
                            .font(BrimChrome.caption)
                            .foregroundStyle(BrimChrome.muted)
                    }
                    Spacer()
                    Button("Check for Updates…") {
                        Task { @MainActor in await BrimUpdateUI.check(from: nil) }
                    }
                }
            }
        }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Pointer / nav button

private enum AppShellPointer {
    static func hand(_ hovering: Bool) {
        if hovering {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }
}

/// Keeps the expanded label (not just the Text) as the pressed/hover hit region.
private struct AppShellNavButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.88 : 1)
    }
}

// MARK: - Cards

private struct AppShellCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(BrimChrome.ink)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(BrimChrome.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(BrimChrome.hairline, lineWidth: 1)
                    )
            )
    }
}

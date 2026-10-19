import AppKit
import IslandCore
import IslandServices
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var settings: AppSettings
    @State private var errorMessage: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var cliMessage: String?
    @State private var expanded: String?

    var body: some View {
        Form {
            connectionsSection
            claudeSection
            islandSection
            terminalSection
            generalSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 600)
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Connections

    private var connectionsSection: some View {
        Section {
            if settings.connections.isEmpty {
                Text("Nothing connected yet. Add Claude Code, Codex, Cursor, Copilot or any other tool below.")
                    .foregroundStyle(.secondary)
            }
            ForEach($settings.connections) { $connection in
                ConnectionRow(
                    connection: $connection,
                    model: model,
                    isExpanded: Binding(get: { expanded == connection.id }, set: { expanded = $0 ? connection.id : nil })
                )
            }
            .onMove { settings.move(from: $0, to: $1) }

            HStack {
                Menu {
                    ForEach(ToolKind.allCases) { kind in
                        Button {
                            let added = model.add(kind)
                            expanded = added.id
                        } label: {
                            Label("\(kind.displayName)\(kind.isExperimental ? " (experimental)" : "") — \(kind.blurb)", systemImage: kind.symbol)
                        }
                    }
                } label: {
                    Label("Add connection", systemImage: "plus")
                }
                .fixedSize()
                Spacer()
                if settings.enabledConnections.isEmpty {
                    Button("Connect all") { model.connectAll() }
                        .disabled(settings.connections.isEmpty)
                } else {
                    Button("Disconnect all") { model.disconnectAll() }
                }
            }
        } header: {
            HStack {
                Text("Connections")
                Spacer()
                Text("\(settings.enabledConnections.count) of \(settings.connections.count) connected")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Add as many as you like, including several of one tool (for example a personal and a work account). Log-based tools are read locally; account-based tools talk only to their own service. Tokens are kept in your Keychain.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Claude plan limits

    private var claudeSection: some View {
        Section {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude plan limits")
                    Text(claudeStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        } header: {
            Text("Plan usage")
        } footer: {
            Text("Codex, Copilot, Cursor and Windsurf report their limits themselves, so they need no extra step.")
                .foregroundStyle(.secondary)
        }
    }

    private var claudeStatusText: String {
        switch model.claudeConnection {
        case .connected:
            return "Connected. Your 5-hour and weekly usage appears after Claude Code's next reply (subscribers only)."
        case .notConnected:
            return "Adds a small status line script to Claude Code so it can share your 5-hour and weekly limits. An existing status line keeps working."
        case .unreadable:
            return "~/.claude/settings.json could not be read. Fix the file, then try again."
        }
    }

    // MARK: Island

    private var islandSection: some View {
        Section("Island") {
            Toggle("Show the island at the top of the screen", isOn: $settings.showIsland)
            Toggle("Expand when the pointer is over it", isOn: $settings.expandOnHover)
            Toggle("Show usage in the menu bar", isOn: $settings.showInMenuBar)
            Toggle("Playful animations (confetti, bouncing icons)", isOn: $settings.playful)
            Picker("Compact view shows", selection: $settings.compactMetric) {
                ForEach(CompactMetric.allCases) { metric in
                    Text(metric.title).tag(metric)
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

    // MARK: Terminal

    private var terminalSection: some View {
        Section {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ai-island command")
                    Text(cliMessage ?? "Connect tools and check usage from the terminal, e.g. ai-island add copilot or ai-island status.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Install") { cliMessage = CommandLineTool.install() }
            }
        } header: {
            Text("Terminal")
        }
    }

    // MARK: General

    private var generalSection: some View {
        Section("General") {
            Picker("Read logs every", selection: $settings.refreshSeconds) {
                Text("5 seconds").tag(5.0)
                Text("10 seconds").tag(10.0)
                Text("30 seconds").tag(30.0)
                Text("1 minute").tag(60.0)
            }
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

    private func run(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - One connection

struct ConnectionRow: View {
    @Binding var connection: Connection
    @ObservedObject var model: UsageModel
    @Binding var isExpanded: Bool
    @State private var token = ""
    @State private var confirmRemove = false
    @State private var justConnected = false

    private var state: ConnectionState { model.states[connection.id] ?? .off }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            details.padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                ToolGlyph(kind: connection.kind, mood: justConnected ? .celebrate : .idle, size: 13, playful: model.settings.playful)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(connection.name)
                        if connection.kind.isExperimental {
                            Text("experimental")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .background(Capsule().fill(Color.orange.opacity(0.2)))
                                .foregroundStyle(.orange)
                        }
                    }
                    HStack(spacing: 5) {
                        statusDot
                        Text(state.summary)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { connection.isEnabled },
                    set: { $0 ? model.connect(connection.id) : model.disconnect(connection.id) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(connection.isEnabled ? "Disconnect" : "Connect")
            }
        }
        .onChange(of: state) { newState in
            if case .connected = newState, !justConnected {
                justConnected = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    justConnected = false
                }
            }
        }
        .confirmationDialog("Remove \(connection.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.remove(connection.id) }
        } message: {
            Text("Its settings and saved token are deleted. You can add it again any time.")
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        let color: Color = {
            switch state {
            case .off: return .gray
            case .checking: return .yellow
            case .connected: return .green
            case .attention: return .orange
            }
        }()
        Circle().fill(color).frame(width: 7, height: 7)
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: $connection.name)

            Picker("Plan", selection: $connection.planID) {
                Text("Automatic").tag(Plans.automatic)
                ForEach(Plans.options(for: connection.kind)) { tier in
                    Text(tier.name).tag(tier.id)
                }
            }

            kindOptions

            if connection.kind.source == .account {
                tokenField
            }

            if case .attention(let problem) = state {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Check now") { model.connect(connection.id) }
                Spacer()
                Button("Remove…", role: .destructive) { confirmRemove = true }
            }
        }
    }

    @ViewBuilder
    private var kindOptions: some View {
        switch connection.kind {
        case .claude, .codex, .customLogs:
            if connection.kind == .customLogs {
                Picker("Log format", selection: option(Connection.Option.format)) {
                    ForEach(LogFormat.allCases, id: \.rawValue) { format in
                        Text(format.displayName).tag(format.rawValue)
                    }
                }
            }
            HStack {
                TextField("Log folder", text: option(Connection.Option.path), prompt: Text(defaultFolder))
                Button("Choose…", action: chooseFolder)
            }
        case .customEndpoint:
            TextField("Usage URL", text: option(Connection.Option.url), prompt: Text("https://api.example.com/usage"))
            HStack {
                TextField("Used value (JSON path)", text: option(Connection.Option.usedPath), prompt: Text("data.used"))
                TextField("Limit (JSON path)", text: option(Connection.Option.limitPath), prompt: Text("data.limit"))
            }
            HStack {
                TextField("Plan name (JSON path)", text: option(Connection.Option.planPath), prompt: Text("optional"))
                TextField("Reset date (JSON path)", text: option(Connection.Option.resetPath), prompt: Text("optional"))
            }
            HStack {
                TextField("Bar label", text: option(Connection.Option.label), prompt: Text("Usage"))
                TextField("Token header", text: option(Connection.Option.authHeader), prompt: Text("Authorization"))
                TextField("Prefix", text: option(Connection.Option.authPrefix), prompt: Text("Bearer "))
            }
        case .cursor, .windsurf, .copilot, .openrouter:
            EmptyView()
        }
    }

    private var tokenField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField(Keychain.has(connection.id) ? "Token saved — paste to replace" : "Token or API key", text: $token)
                Button("Save") {
                    model.connect(connection.id, token: token)
                    token = ""
                }
                .disabled(token.isEmpty)
            }
            Text(AccountFetcher.canAutoConnect(connection.kind)
                 ? "Optional. Without a token, AI Island uses your existing sign-in on this Mac. " + AccountFetcher.tokenHelp(for: connection.kind)
                 : AccountFetcher.tokenHelp(for: connection.kind))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func option(_ key: String) -> Binding<String> {
        Binding(get: { connection.options[key] ?? "" }, set: { connection.options[key] = $0 })
    }

    private var defaultFolder: String {
        guard let format = connection.logFormat, connection.kind != .customLogs else { return "Choose a folder" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = DefaultLogLocations.roots(for: format).first?.path ?? ""
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the folder with \(connection.name)'s .jsonl logs"
        if panel.runModal() == .OK, let url = panel.url {
            connection.options[Connection.Option.path] = url.path
        }
    }
}

// MARK: - Command-line tool

/// Links the `ai-island` command shipped inside the app bundle into the user's PATH.
enum CommandLineTool {
    static func install() -> String {
        let source = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ai-island")
        guard FileManager.default.isExecutableFile(atPath: source.path) else {
            return "This build doesn't include the command. Build with ./scripts/build-app.sh, or run: swift build -c release --product ai-island"
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [URL(fileURLWithPath: "/usr/local/bin"), URL(fileURLWithPath: "/opt/homebrew/bin"), home.appendingPathComponent(".local/bin")]
        for directory in candidates {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard FileManager.default.isWritableFile(atPath: directory.path) else { continue }
            let link = directory.appendingPathComponent("ai-island")
            try? FileManager.default.removeItem(at: link)
            do {
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
            } catch {
                continue
            }
            let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { $0 == directory.path }
            return "Installed at \(link.path). Try: ai-island status"
                + (onPath || directory.path != home.appendingPathComponent(".local/bin").path ? "" : "\nAdd ~/.local/bin to your PATH: echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.zshrc")
        }
        return "Couldn't write to /usr/local/bin or ~/.local/bin. Run: sudo ln -sf \"\(source.path)\" /usr/local/bin/ai-island"
    }
}

import AppKit
import IslandCore
import IslandServices
import SwiftUI

/// What the Add Account window should open on.
struct AddAccountRequest: Equatable, Identifiable {
    /// Skip the tool list and open this tool's form.
    var kind: ToolKind?
    /// Sign this connection in again instead of adding a new one.
    var connectionID: String?
    /// First run: welcome copy and a Done button.
    var welcome = false

    var id: String { "\(kind?.rawValue ?? "")|\(connectionID ?? "")|\(welcome)" }
}

/// Adds an account of any tool, or signs an existing one in again, without the Terminal.
struct AddAccountView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var settings: AppSettings
    let request: AddAccountRequest
    let done: () -> Void
    @State private var kind: ToolKind?
    @State private var found = Set<ToolKind>()

    init(model: UsageModel, settings: AppSettings, request: AddAccountRequest, done: @escaping () -> Void) {
        self.model = model
        self.settings = settings
        self.request = request
        self.done = done
        let existing = request.connectionID.flatMap { settings.connection($0) }
        _kind = State(initialValue: existing?.kind ?? request.kind)
    }

    private var existing: Connection? { request.connectionID.flatMap { settings.connection($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let kind {
                form(for: kind)
            } else {
                picker
            }
        }
        .padding(22)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Tool list

    private var picker: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.welcome ? "Welcome to Brim" : "Add an account")
                    .font(.title2.bold())
                Text(request.welcome
                     ? "Connect the AI tools you use to see tokens and plan limits in the notch. You can add several accounts of one tool."
                     : "Pick a tool. You can add as many accounts as you like, including several of one tool.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(ToolKind.allCases) { kind in
                    Button { self.kind = kind } label: { tile(kind) }
                        .buttonStyle(.plain)
                }
            }
            if request.welcome {
                HStack {
                    Text("\(settings.enabledConnections.count) connected")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Done", action: done)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .task {
            found = await Task.detached { LocalSignIns.found() }.value
        }
    }

    private func tile(_ kind: ToolKind) -> some View {
        let count = settings.connections.filter { $0.kind == kind }.count
        return HStack(alignment: .top, spacing: 10) {
            GlyphTile(kind: kind)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(kind.displayName).font(.body.weight(.semibold))
                    if kind.isExperimental {
                        Text("experimental")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .background(Capsule().fill(Color.secondary.opacity(0.18)))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(count > 0 ? "\(count) added · add another" : found.contains(kind) ? "Found on this Mac" : kind.blurb)
                    .font(.caption)
                    .foregroundStyle(found.contains(kind) && count == 0 ? Color.green : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
    }

    // MARK: One tool

    @ViewBuilder
    private func form(for kind: ToolKind) -> some View {
        HStack(spacing: 8) {
            if existing == nil, request.kind == nil {
                Button { self.kind = nil } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help("All tools")
            }
            GlyphTile(kind: kind, name: existing?.name)
            Text(existing.map { "Sign in \($0.name)" } ?? "Add \(kind.displayName)")
                .font(.title2.bold())
        }
        switch kind {
        case .copilot:
            CopilotSignIn(connected: model.connectedGitHubLogins(), finish: finish)
        case .cursor, .windsurf:
            AppSignIn(kind: kind, showEmail: settings.showAccountEmails,
                      signInTaken: existing == nil && settings.connections.contains { $0.kind == kind && !Keychain.has($0.id) },
                      finish: finish)
        case .openrouter:
            KeyEntry(prompt: "API key", help: "Create a key at openrouter.ai/keys and paste it here. It's kept in your Keychain.",
                     link: URL(string: "https://openrouter.ai/keys"), finish: finish)
        case .customEndpoint:
            EndpointEntry(finish: finish)
        case .claude, .codex, .customLogs:
            LogFolderEntry(kind: kind, defaultTaken: settings.connections.contains { $0.kind == kind && $0.usesDefaultLocation },
                           model: model, done: done, finish: finish)
        }
    }

    private func finish(_ options: [String: String], _ token: String?) {
        if let existing {
            model.reconnect(existing.id, options: options, token: token)
        } else if let kind {
            model.addAccount(kind, options: options, token: token)
        }
        if request.welcome, existing == nil {
            kind = nil
        } else {
            done()
        }
    }
}

/// A tool's glyph on the 28pt black tile, so light logos read on a light window.
struct GlyphTile: View {
    let kind: ToolKind
    var name: String?

    var body: some View {
        ToolGlyph(kind: kind, mood: .idle, size: 15, playful: false, name: name)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black))
            .environment(\.colorScheme, .dark)
    }
}

typealias FinishAccount = (_ options: [String: String], _ token: String?) -> Void

// MARK: - GitHub Copilot

/// The GitHub CLI's accounts, a browser sign-in, or a pasted token.
private struct CopilotSignIn: View {
    let connected: Set<String>
    let finish: FinishAccount
    @State private var accounts: [GitHubAccount] = []
    @State private var loaded = false
    @State private var code: GitHubDeviceFlow.Code?
    @State private var waiting: Task<Void, Never>?
    @State private var problem: String?
    @State private var token = ""
    @State private var showToken = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !accounts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Signed in on this Mac (GitHub CLI)").font(.headline)
                    ForEach(accounts) { account in
                        HStack {
                            Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                            Text(account.login).textSelection(.enabled)
                            if account.isActive { Text("active").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if connected.contains(account.login) {
                                Text("Added").foregroundStyle(.secondary)
                            } else {
                                Button("Add") { finish([Connection.Option.githubLogin: account.login], nil) }
                            }
                        }
                    }
                }
                Divider()
            } else if !loaded {
                ProgressView().controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(accounts.isEmpty ? "Sign in" : "Another GitHub account").font(.headline)
                if let code {
                    Text("Enter this code on GitHub, then come back here:")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Text(code.userCode)
                            .font(.system(size: 26, weight: .bold, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy Code and Open GitHub") { openGitHub(code) }
                            .keyboardShortcut(.defaultAction)
                    }
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for GitHub…").foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { cancel() }
                    }
                } else {
                    Button("Sign in with GitHub…") { startSignIn() }
                    Text("Opens github.com in your browser. To add a different account, sign in to it there first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            DisclosureGroup("Paste a token instead", isExpanded: $showToken) {
                HStack {
                    SecureField("GitHub token", text: $token)
                    Button("Add") { finish([:], token) }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 4)
            }
        }
        .task {
            accounts = await Task.detached { GitHubCLI.accounts() }.value
            loaded = true
        }
        .onDisappear { waiting?.cancel() }
    }

    private func startSignIn() {
        problem = nil
        waiting?.cancel()
        waiting = Task {
            do {
                let code = try await GitHubDeviceFlow.start()
                self.code = code
                openGitHub(code)
                let token = try await GitHubDeviceFlow.token(for: code)
                self.code = nil
                finish([:], token)
            } catch is CancellationError {
                code = nil
            } catch {
                code = nil
                problem = error.localizedDescription
            }
        }
    }

    private func openGitHub(_ code: GitHubDeviceFlow.Code) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code.userCode, forType: .string)
        NSWorkspace.shared.open(code.verificationURL)
    }

    private func cancel() {
        waiting?.cancel()
        waiting = nil
        code = nil
    }
}

// MARK: - Cursor and Windsurf

/// These tools sign in inside their own app; Brim reads that sign-in.
private struct AppSignIn: View {
    let kind: ToolKind
    let showEmail: Bool
    /// A connection already uses the app's sign-in, so adding it again would count it twice.
    let signInTaken: Bool
    let finish: FinishAccount
    @State private var status: LocalSignIns.AppStatus?
    @State private var token = ""
    @State private var showToken: Bool

    init(kind: ToolKind, showEmail: Bool, signInTaken: Bool, finish: @escaping FinishAccount) {
        self.kind = kind
        self.showEmail = showEmail
        self.signInTaken = signInTaken
        self.finish = finish
        _showToken = State(initialValue: signInTaken)
    }

    private var appName: String { kind.displayName }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Brim uses the account you're signed in to in the \(appName) app. Sign in there, then check.")
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                switch status {
                case nil:
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                case .notInstalled?:
                    Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                    Text("\(appName) isn't installed on this Mac.").foregroundStyle(.secondary)
                case .signedOut?:
                    Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(.orange)
                    Text("Not signed in to \(appName) yet.").foregroundStyle(.secondary)
                case .signedIn(let email)?:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(email.flatMap { showEmail ? "Signed in as \($0)" : nil } ?? "Signed in to \(appName)")
                        .textSelection(.enabled)
                }
            }

            HStack {
                if status == .notInstalled {
                    Button("Get \(appName)") { NSWorkspace.shared.open(LocalSignIns.downloadURL(kind)) }
                } else {
                    Button("Open \(appName)") { LocalSignIns.openApp(kind) }
                }
                Button("Check Now") { check() }
                Spacer()
                if signInTaken {
                    Text("Already added").foregroundStyle(.secondary)
                } else {
                    Button("Add \(appName)") { finish([:], nil) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!(status?.isSignedIn ?? false))
                }
            }

            DisclosureGroup("Another \(appName) account", isExpanded: $showToken) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(kind == .cursor
                         ? "The Cursor app signs in one account at a time. For another account, sign in to it on cursor.com in your browser and paste its WorkosCursorSessionToken cookie here."
                         : "The Windsurf app signs in one account at a time. For another account, paste that account's Windsurf API key here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        SecureField(kind == .cursor ? "Session token" : "API key", text: $token)
                        Button("Add") { finish([:], token) }
                            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.top, 4)
            }
        }
        .onAppear(perform: check)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in check() }
    }

    private func check() {
        let kind = kind
        Task { status = await Task.detached { LocalSignIns.appStatus(kind) }.value }
    }
}

// MARK: - API keys and endpoints

private struct KeyEntry: View {
    let prompt: String
    let help: String
    let link: URL?
    let finish: FinishAccount
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SecureField(prompt, text: $key)
                Button("Add") { finish([:], key) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: 4) {
                Text(help).foregroundStyle(.secondary)
                if let link { Link("Open", destination: link) }
            }
            .font(.caption)
        }
    }
}

private struct EndpointEntry: View {
    let finish: FinishAccount
    @State private var url = ""
    @State private var used = ""
    @State private var limit = ""
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Usage URL", text: $url, prompt: Text("https://api.example.com/usage"))
            HStack {
                TextField("Used value (JSON path)", text: $used, prompt: Text("data.used"))
                TextField("Limit (JSON path)", text: $limit, prompt: Text("data.limit"))
            }
            SecureField("Token (optional, sent as Authorization: Bearer …)", text: $token)
            HStack {
                Text("More options (plan, reset date, header) are in Settings → Connections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add") {
                    typealias O = Connection.Option
                    finish([O.url: url, O.usedPath: used, O.limitPath: limit, O.authHeader: "Authorization", O.authPrefix: "Bearer "], token)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!(url.hasPrefix("https://") || url.hasPrefix("http://")) || used.isEmpty)
            }
        }
    }
}

// MARK: - Log-based tools

private struct LogFolderEntry: View {
    let kind: ToolKind
    let defaultTaken: Bool
    @ObservedObject var model: UsageModel
    let done: () -> Void
    let finish: FinishAccount
    @State private var format = LogFormat.claude.rawValue
    @State private var label = ""
    @State private var signingIn = false
    @State private var problem: String?

    private var defaultFolder: String? {
        guard let format = kind == .codex ? LogFormat.codex : kind == .claude ? LogFormat.claude : nil,
              let path = DefaultLogLocations.roots(for: format).first?.path else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if kind == .claude, ClaudeAccounts.canSignIn {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sign in to another Claude account").font(.headline)
                    HStack {
                        TextField("Label", text: $label, prompt: Text("Work"))
                        Button("Sign In…") { signInClaude() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(signingIn)
                    }
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    }
                }
                Divider()
            }

            Text(intro)
                .fixedSize(horizontal: false, vertical: true)
            if kind == .customLogs {
                Picker("Log format", selection: $format) {
                    ForEach(LogFormat.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
                }
            }
            HStack {
                if let defaultFolder, !defaultTaken {
                    Button("Use \(defaultFolder)") { finish([:], nil) }
                }
                Button("Choose Folder…", action: chooseFolder)
                Spacer()
            }
        }
    }

    private var intro: String {
        switch kind {
        case .claude:
            return defaultTaken
                ? "Each Claude Code profile keeps its own logs. Choose the projects folder of the other profile (inside its CLAUDE_CONFIG_DIR)."
                : "Brim reads Claude Code's local logs; nothing leaves your Mac."
        case .codex:
            return defaultTaken
                ? "Each Codex profile keeps its own logs. Choose the sessions folder of the other profile (inside its CODEX_HOME)."
                : "Brim reads the Codex CLI's local logs; nothing leaves your Mac."
        default:
            return "Choose any folder of Claude Code or Codex style .jsonl logs."
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.message = "Choose the folder with the .jsonl logs"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var options = [Connection.Option.path: url.path]
        if kind == .customLogs { options[Connection.Option.format] = format }
        finish(options, nil)
    }

    private func signInClaude() {
        guard let add = ClaudeAccounts.addAccount else { return }
        signingIn = true
        problem = nil
        let label = label.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                _ = try await add(label.isEmpty ? "Claude" : label)
                done()
            } catch {
                problem = error.localizedDescription
            }
            signingIn = false
        }
    }
}

// MARK: - Local sign-ins

/// What's already signed in on this Mac. Reads local files and app state only.
enum LocalSignIns {
    enum AppStatus: Equatable {
        case notInstalled
        case signedOut
        case signedIn(email: String?)

        var isSignedIn: Bool { if case .signedIn = self { return true } else { return false } }
    }

    private static let bundleIDs: [ToolKind: String] = [
        .cursor: "com.todesktop.230313mzl4w4u92",
        .windsurf: "com.exafunction.windsurf",
    ]

    static func appURL(_ kind: ToolKind) -> URL? {
        if let id = bundleIDs[kind], let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        let fallback = URL(fileURLWithPath: "/Applications/\(kind.displayName).app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    static func appStatus(_ kind: ToolKind) -> AppStatus {
        switch kind {
        case .cursor:
            if VSCodeState.value(app: "Cursor", key: "cursorAuth/accessToken") != nil {
                return .signedIn(email: VSCodeState.value(app: "Cursor", key: "cursorAuth/cachedEmail"))
            }
        case .windsurf:
            if VSCodeState.windsurfAPIKey() != nil { return .signedIn(email: nil) }
        default:
            break
        }
        return appURL(kind) == nil ? .notInstalled : .signedOut
    }

    static func openApp(_ kind: ToolKind) {
        guard let url = appURL(kind) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func downloadURL(_ kind: ToolKind) -> URL {
        URL(string: kind == .cursor ? "https://cursor.com/download" : "https://windsurf.com/download")!
    }

    /// Tools with a sign-in or logs on this Mac.
    static func found() -> Set<ToolKind> {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var kinds = Set<ToolKind>()
        if DefaultLogLocations.roots(for: .claude).contains(where: { FileManager.default.fileExists(atPath: $0.path) }) { kinds.insert(.claude) }
        if FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path) { kinds.insert(.codex) }
        for kind in [ToolKind.cursor, .windsurf] where appStatus(kind).isSignedIn { kinds.insert(kind) }
        if !GitHubCLI.accounts().isEmpty { kinds.insert(.copilot) }
        return kinds
    }
}

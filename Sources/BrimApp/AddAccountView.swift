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
/// Branded Brim chrome — dark, atmospheric, not Settings.app.
struct AddAccountView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var settings: AppSettings
    let request: AddAccountRequest
    let done: () -> Void
    @State private var kind: ToolKind?
    @State private var found = Set<ToolKind>()
    /// Surfaced when `finish` refuses a duplicate Claude email (must be visible, never silent).
    @State private var finishProblem: String?

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
        ZStack {
            AddChrome.backdrop
            VStack(alignment: .leading, spacing: 0) {
                if let kind {
                    form(for: kind)
                } else {
                    picker
                }
                if let finishProblem {
                    Label(finishProblem, systemImage: "exclamationmark.triangle.fill")
                        .font(AddChrome.caption)
                        .foregroundStyle(Brand.attention)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 24)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Tool list

    private var picker: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Brim")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .tracking(1.2)
                Text(request.welcome ? "Welcome" : "Connect")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text(request.welcome
                     ? "Choose the AI tools you use. Plan limits and tokens show in the notch."
                     : "Pick a tool, then sign in. You can add several accounts of one tool.")
                    .font(.system(size: 13.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 6) {
                ForEach(ToolKind.allCases) { kind in
                    Button { self.kind = kind } label: { toolRow(kind) }
                        .buttonStyle(.plain)
                }
            }

            if request.welcome {
                HStack {
                    Text("\(settings.enabledConnections.count) connected")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.4))
                    Spacer()
                    AddChrome.primaryButton("Done", action: done)
                }
                .padding(.top, 4)
            }
        }
        .task {
            found = await Task.detached { LocalSignIns.found() }.value
        }
    }

    private func toolRow(_ kind: ToolKind) -> some View {
        let count = settings.connections.filter { $0.kind == kind }.count
        let status: String = {
            if count > 0 { return "\(count) added · add another" }
            if found.contains(kind) { return "Found on this Mac" }
            return kind.blurb
        }()
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(kind.tint)
                .frame(width: 3, height: 28)
            GlyphTile(kind: kind)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kind.displayName)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    if kind.isExperimental {
                        Text("experimental")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                }
                Text(status)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(found.contains(kind) && count == 0 ? Brand.good : Color.white.opacity(0.4))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.25))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .contentShape(Rectangle())
    }

    // MARK: One tool

    @ViewBuilder
    private func form(for kind: ToolKind) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                if existing == nil, request.kind == nil {
                    Button { self.kind = nil } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("All tools")
                }
                GlyphTile(kind: kind, name: existing?.name)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Brim")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.35))
                        .tracking(0.8)
                    Text(existing.map { "Sign in \($0.name)" } ?? "Add \(kind.displayName)")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                }
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
            case .claude:
                ClaudeSignIn(defaultTaken: settings.connections.contains { $0.kind == .claude && $0.usesDefaultLocation },
                             model: model, settings: settings, done: done, finish: finish)
            case .codex, .customLogs:
                LogFolderEntry(kind: kind, defaultTaken: settings.connections.contains { $0.kind == kind && $0.usesDefaultLocation },
                               finish: finish)
            }
        }
    }

    private func finish(_ options: [String: String], _ token: String?) {
        finishProblem = nil
        var options = options
        if kind == .claude || existing?.kind == .claude {
            let probe = Connection(kind: .claude, options: options)
            if let dir = probe.claudeConfigDir() {
                let account = ClaudeAccounts.account(configDir: dir)
                if let email = account.email {
                    let normalized = AccountEmail.normalize(email)
                    if let dup = ClaudeDuplicateEmail.existing(email: normalized, in: settings.connections, excluding: existing?.id),
                       ClaudeDuplicateEmail.isDuplicate(email: normalized, candidateConfigDir: dir, against: dup) {
                        finishProblem = ClaudeDuplicateEmail.userMessage(email: normalized)
                        return
                    }
                    options[Connection.Option.accountEmail] = normalized
                }
            } else if let email = options[Connection.Option.accountEmail],
                      ClaudeDuplicateEmail.existing(email: email, in: settings.connections, excluding: existing?.id) != nil {
                finishProblem = ClaudeDuplicateEmail.userMessage(email: email)
                return
            }
        }
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

// MARK: - Brim chrome

enum AddChrome {
    static var backdrop: some View {
        ZStack {
            BrimChrome.canvas
            RadialGradient(
                colors: [Color(red: 0.85, green: 0.47, blue: 0.34).opacity(0.18), .clear],
                center: .topLeading, startRadius: 20, endRadius: 320
            )
            RadialGradient(
                colors: [Color(red: 0.45, green: 0.78, blue: 1.0).opacity(0.1), .clear],
                center: .bottomTrailing, startRadius: 10, endRadius: 280
            )
            LinearGradient(
                colors: [Color.white.opacity(0.04), .clear],
                startPoint: .top, endPoint: .center
            )
        }
        .ignoresSafeArea()
    }

    static func primaryButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        BrimChrome.primaryButton(title, enabled: enabled, action: action)
            .keyboardShortcut(.defaultAction)
    }

    static func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.75))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    static func fieldBackground() -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.08))
    }

    static var sectionLabel: Font { .system(size: 13, weight: .semibold, design: .rounded) }
    static var bodyCopy: Font { .system(size: 13, weight: .medium, design: .rounded) }
    static var caption: Font { .system(size: 11.5, weight: .medium, design: .rounded) }
}

/// A tool's glyph on the 28pt black tile, so logos read on the dark window.
struct GlyphTile: View {
    let kind: ToolKind
    var name: String?

    var body: some View {
        ToolGlyph(kind: kind, mood: .idle, size: 15, playful: false, name: name)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.08)))
            .environment(\.colorScheme, .dark)
    }
}

typealias FinishAccount = (_ options: [String: String], _ token: String?) -> Void

// MARK: - Claude (browser / API primary)

/// Plan limits via Anthropic OAuth. Local Claude Code logs are optional / advanced.
private struct ClaudeSignIn: View {
    let defaultTaken: Bool
    @ObservedObject var model: UsageModel
    @ObservedObject var settings: AppSettings
    let done: () -> Void
    let finish: FinishAccount
    @State private var label = ""
    @State private var signingIn = false
    @State private var problem: String?
    @State private var showAdvanced = false

    private var installed: Bool { ClaudeCode.executable() != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in to Claude to show plan limits (5-hour and weekly) in the notch. Works for accounts you use on claude.ai — not only Claude Code.")
                .font(AddChrome.bodyCopy)
                .foregroundStyle(Color.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Text("Account name")
                    .font(AddChrome.caption)
                    .foregroundStyle(Color.white.opacity(0.4))
                TextField("Optional", text: $label, prompt: Text("Work, personal…"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(AddChrome.fieldBackground())
                    .disabled(signingIn)
            }

            if signingIn {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…")
                        .font(AddChrome.bodyCopy)
                        .foregroundStyle(Color.white.opacity(0.6))
                    Spacer()
                    Button("Cancel") {
                        // Cancellation is handled by discarding the task via view lifecycle;
                        // re-tap Sign in starts fresh.
                        signingIn = false
                        problem = nil
                    }
                    .font(AddChrome.caption)
                    .foregroundStyle(Color.white.opacity(0.5))
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 10) {
                    AddChrome.primaryButton("Sign in with Claude…", enabled: installed && ClaudeAccountHook.canSignIn) {
                        signInClaude()
                    }
                    if !installed {
                        AddChrome.secondaryButton("Get Claude Code") {
                            NSWorkspace.shared.open(URL(string: "https://claude.com/claude-code")!)
                        }
                    }
                }
                if !installed {
                    Text("Claude Code is installed once so Brim can complete the browser sign-in. You won't use the Terminal.")
                        .font(AddChrome.caption)
                        .foregroundStyle(Brand.attention.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Opens claude.ai in your browser. Brim never sees your password or token.")
                        .font(AddChrome.caption)
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(AddChrome.caption)
                    .foregroundStyle(Brand.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("claude-duplicate-email")
            }

            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Only if you want Claude Code session detail (tokens, models, cache) or a second Code profile on this Mac. Plan limits do not need this.")
                        .font(AddChrome.caption)
                        .foregroundStyle(Color.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        if !defaultTaken {
                            AddChrome.secondaryButton("Use this Mac’s Claude Code logs") {
                                addOptionalLogs([:])
                            }
                        }
                        AddChrome.secondaryButton("Choose folder…", action: chooseFolder)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Claude Code session logs (optional)")
                    .font(AddChrome.caption)
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            .tint(Color.white.opacity(0.45))
        }
        .onAppear {
            // QA / screenshot: BRIM_DEMO_DUP_EMAIL=you@example.com with BRIM_OPEN_ADD=1
            if problem == nil, let demo = Self.demoDuplicateProblem {
                problem = demo
            }
        }
    }

    private func signInClaude() {
        guard let add = ClaudeAccountHook.addAccount else {
            problem = "Sign-in isn’t ready yet. Quit and reopen Brim, then try again."
            return
        }
        signingIn = true
        problem = nil
        let label = label.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let account = try await add(label.isEmpty ? "Claude" : label)
                // Check when email is known (after OAuth), including “Claude Code” vs “Claude · Personal”.
                if let email = account.email,
                   let existing = ClaudeDuplicateEmail.existing(email: email, in: settings.connections),
                   ClaudeDuplicateEmail.isDuplicate(email: email, candidateConfigDir: account.configDir, against: existing) {
                    problem = ClaudeDuplicateEmail.userMessage(email: email)
                    signingIn = false
                    return
                }
                _ = try model.addClaudeConnection(for: account)
                done()
            } catch let error as ClaudeAccountSetupError {
                problem = error.errorDescription ?? error.localizedDescription
                signingIn = false
            } catch {
                problem = error.localizedDescription
                signingIn = false
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.message = "Choose the Claude Code projects folder with .jsonl session logs"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addOptionalLogs([Connection.Option.path: url.path])
    }

    /// Optional session-log path only. Refuses if that folder’s auth email is already connected.
    private func addOptionalLogs(_ options: [String: String]) {
        let probe = Connection(kind: .claude, options: options)
        if let dir = probe.claudeConfigDir() {
            let account = ClaudeAccounts.account(configDir: dir)
            if let email = account.email,
               let existing = ClaudeDuplicateEmail.existing(email: email, in: settings.connections),
               ClaudeDuplicateEmail.isDuplicate(email: email, candidateConfigDir: dir, against: existing) {
                problem = ClaudeDuplicateEmail.userMessage(email: email)
                return
            }
            var options = options
            if let email = account.email {
                options[Connection.Option.accountEmail] = AccountEmail.normalize(email)
            }
            finish(options, nil)
            return
        }
        finish(options, nil)
    }
}

// MARK: - QA / screenshot hook

extension ClaudeSignIn {
    /// `BRIM_DEMO_DUP_EMAIL=you@example.com` shows the visible duplicate error without a live OAuth loop.
    fileprivate static var demoDuplicateProblem: String? {
        guard let email = ProcessInfo.processInfo.environment["BRIM_DEMO_DUP_EMAIL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty
        else { return nil }
        return ClaudeDuplicateEmail.userMessage(email: email)
    }
}

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
                VStack(alignment: .leading, spacing: 8) {
                    Text("Signed in on this Mac")
                        .font(AddChrome.sectionLabel)
                        .foregroundStyle(Color.white.opacity(0.7))
                    ForEach(accounts) { account in
                        HStack {
                            Image(systemName: "person.crop.circle").foregroundStyle(Color.white.opacity(0.45))
                            Text(account.login)
                                .font(AddChrome.bodyCopy)
                                .foregroundStyle(.white)
                                .textSelection(.enabled)
                            if account.isActive {
                                Text("active")
                                    .font(AddChrome.caption)
                                    .foregroundStyle(Color.white.opacity(0.35))
                            }
                            Spacer()
                            if connected.contains(account.login) {
                                Text("Added").font(AddChrome.caption).foregroundStyle(Color.white.opacity(0.35))
                            } else {
                                AddChrome.secondaryButton("Add") {
                                    finish([Connection.Option.githubLogin: account.login], nil)
                                }
                            }
                        }
                    }
                }
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            } else if !loaded {
                ProgressView().controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(accounts.isEmpty ? "Sign in" : "Another GitHub account")
                    .font(AddChrome.sectionLabel)
                    .foregroundStyle(Color.white.opacity(0.7))
                if let code {
                    Text("Enter this code on GitHub, then come back here:")
                        .font(AddChrome.bodyCopy)
                        .foregroundStyle(Color.white.opacity(0.5))
                    HStack(spacing: 12) {
                        Text(code.userCode)
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                        AddChrome.primaryButton("Copy & open GitHub") { openGitHub(code) }
                    }
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for GitHub…")
                            .font(AddChrome.caption)
                            .foregroundStyle(Color.white.opacity(0.45))
                        Spacer()
                        Button("Cancel") { cancel() }
                            .font(AddChrome.caption)
                            .foregroundStyle(Color.white.opacity(0.5))
                            .buttonStyle(.plain)
                    }
                } else {
                    AddChrome.primaryButton("Sign in with GitHub…") { startSignIn() }
                    Text("Opens github.com in your browser. To add a different account, sign in to it there first.")
                        .font(AddChrome.caption)
                        .foregroundStyle(Color.white.opacity(0.35))
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(AddChrome.caption)
                        .foregroundStyle(Brand.attention)
                }
            }

            DisclosureGroup("Paste a token instead", isExpanded: $showToken) {
                HStack(spacing: 8) {
                    SecureField("GitHub token", text: $token)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(AddChrome.fieldBackground())
                    AddChrome.primaryButton("Add", enabled: !token.trimmingCharacters(in: .whitespaces).isEmpty) {
                        finish([:], token)
                    }
                }
                .padding(.top, 6)
            }
            .font(AddChrome.caption)
            .foregroundStyle(Color.white.opacity(0.45))
            .tint(Color.white.opacity(0.45))
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
                .font(AddChrome.bodyCopy)
                .foregroundStyle(Color.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                switch status {
                case nil:
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(AddChrome.caption).foregroundStyle(Color.white.opacity(0.45))
                case .notInstalled?:
                    Image(systemName: "xmark.circle").foregroundStyle(Color.white.opacity(0.4))
                    Text("\(appName) isn't installed on this Mac.")
                        .font(AddChrome.caption).foregroundStyle(Color.white.opacity(0.45))
                case .signedOut?:
                    Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(Brand.attention)
                    Text("Not signed in to \(appName) yet.")
                        .font(AddChrome.caption).foregroundStyle(Color.white.opacity(0.55))
                case .signedIn(let email)?:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.good)
                    Text(email.flatMap { showEmail ? "Signed in as \($0)" : nil } ?? "Signed in to \(appName)")
                        .font(AddChrome.bodyCopy).foregroundStyle(.white)
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 8) {
                if status == .notInstalled {
                    AddChrome.secondaryButton("Get \(appName)") { NSWorkspace.shared.open(LocalSignIns.downloadURL(kind)) }
                } else {
                    AddChrome.secondaryButton("Open \(appName)") { LocalSignIns.openApp(kind) }
                }
                AddChrome.secondaryButton("Check now") { check() }
                Spacer()
                if signInTaken {
                    Text("Already added").font(AddChrome.caption).foregroundStyle(Color.white.opacity(0.35))
                } else {
                    AddChrome.primaryButton("Add \(appName)", enabled: status?.isSignedIn ?? false) {
                        finish([:], nil)
                    }
                }
            }

            DisclosureGroup("Another \(appName) account", isExpanded: $showToken) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(kind == .cursor
                         ? "The Cursor app signs in one account at a time. For another account, sign in to it on cursor.com in your browser and paste its WorkosCursorSessionToken cookie here."
                         : "The Windsurf app signs in one account at a time. For another account, paste that account's Windsurf API key here.")
                        .font(AddChrome.caption)
                        .foregroundStyle(Color.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        SecureField(kind == .cursor ? "Session token" : "API key", text: $token)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(AddChrome.fieldBackground())
                        AddChrome.primaryButton("Add", enabled: !token.trimmingCharacters(in: .whitespaces).isEmpty) {
                            finish([:], token)
                        }
                    }
                }
                .padding(.top, 6)
            }
            .font(AddChrome.caption)
            .foregroundStyle(Color.white.opacity(0.45))
            .tint(Color.white.opacity(0.45))
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SecureField(prompt, text: $key)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(AddChrome.fieldBackground())
                AddChrome.primaryButton("Add", enabled: !key.trimmingCharacters(in: .whitespaces).isEmpty) {
                    finish([:], key)
                }
            }
            HStack(spacing: 4) {
                Text(help)
                    .font(AddChrome.caption)
                    .foregroundStyle(Color.white.opacity(0.4))
                if let link {
                    Link("Open", destination: link)
                        .font(AddChrome.caption)
                        .foregroundStyle(Color.white.opacity(0.7))
                }
            }
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
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .padding(10)
                .background(AddChrome.fieldBackground())
            HStack(spacing: 8) {
                TextField("Used (JSON path)", text: $used, prompt: Text("data.used"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(AddChrome.fieldBackground())
                TextField("Limit (JSON path)", text: $limit, prompt: Text("data.limit"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(AddChrome.fieldBackground())
            }
            SecureField("Token (optional, Authorization: Bearer …)", text: $token)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .padding(10)
                .background(AddChrome.fieldBackground())
            HStack {
                Text("More options (plan, reset, header) are in Settings → Connections.")
                    .font(AddChrome.caption)
                    .foregroundStyle(Color.white.opacity(0.35))
                Spacer()
                AddChrome.primaryButton("Add", enabled: (url.hasPrefix("https://") || url.hasPrefix("http://")) && !used.isEmpty) {
                    typealias O = Connection.Option
                    finish([O.url: url, O.usedPath: used, O.limitPath: limit, O.authHeader: "Authorization", O.authPrefix: "Bearer "], token)
                }
            }
        }
    }
}

// MARK: - Log-based tools (Codex / custom)

private struct LogFolderEntry: View {
    let kind: ToolKind
    let defaultTaken: Bool
    let finish: FinishAccount
    @State private var format = LogFormat.claude.rawValue

    private var defaultFolder: String? {
        guard let format = kind == .codex ? LogFormat.codex : kind == .claude ? LogFormat.claude : nil,
              let path = DefaultLogLocations.roots(for: format).first?.path else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(intro)
                .font(AddChrome.bodyCopy)
                .foregroundStyle(Color.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            if kind == .customLogs {
                Picker("Log format", selection: $format) {
                    ForEach(LogFormat.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }
            HStack(spacing: 8) {
                if let defaultFolder, !defaultTaken {
                    AddChrome.primaryButton("Use \(defaultFolder)") { finish([:], nil) }
                }
                AddChrome.secondaryButton("Choose folder…", action: chooseFolder)
                Spacer()
            }
        }
    }

    private var intro: String {
        switch kind {
        case .codex:
            return defaultTaken
                ? "Each Codex profile keeps its own logs. Choose the sessions folder of the other profile."
                : "Brim reads the Codex CLI’s local logs on this Mac. Nothing leaves your Mac."
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

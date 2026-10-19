import Foundation
import IslandCore

// MARK: - Claude Code on this Mac

public enum ClaudeCode {
    /// The `claude` command, wherever its installers put it. GUI apps don't get the shell's PATH,
    /// so the usual install locations are checked as well.
    public static func executable(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        if let custom = environment["BRIM_CLAUDE_PATH"], !custom.isEmpty { return URL(fileURLWithPath: custom) }
        let fixed = [".local/bin/claude", ".claude/local/claude", ".npm-global/bin/claude", ".bun/bin/claude", ".volta/bin/claude"]
            .map { home.appendingPathComponent($0).path } + ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        let fromPath = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        return (fixed + fromPath).first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    /// Runs `claude` with `CLAUDE_CONFIG_DIR` set to `configDir`; output is captured, never logged.
    static func process(_ arguments: [String], configDir: URL, executable: URL) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = configDir.path
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = executable.deletingLastPathComponent().path + ":" + path
        process.environment = environment
        return process
    }
}

// MARK: - Live limits

public enum ClaudeUsageError: LocalizedError {
    case notSignedIn
    case expired
    case rejected
    case http(Int)
    case unexpected

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in to Claude Code in this folder."
        case .expired: return "Sign-in expired. Open Claude Code to refresh."
        case .rejected: return "Claude didn't accept the sign-in. Open Claude Code to refresh."
        case .http(let code): return "Claude's usage service returned an error (HTTP \(code))."
        case .unexpected: return "Claude's usage service answered in a format Brim doesn't understand yet."
        }
    }
}

/// Reads an account's plan limits from Anthropic, the same request Claude Code's `/usage` makes.
/// Uses the access token Claude Code keeps in the Keychain, read at call time and never stored,
/// refreshed or logged. Nothing is sent anywhere but api.anthropic.com.
public enum ClaudeUsageFetcher {
    static let url = URL(string: "https://api.anthropic.com/api/oauth/usage?at_wall=1&skip_spend=1")!

    public static func fetch(_ account: ClaudeAccount, now: Date = Date()) async throws -> [PlanWindow] {
        guard let credentials = credentials(for: account) else { throw ClaudeUsageError.notSignedIn }
        guard !credentials.isExpired(now: now) else { throw ClaudeUsageError.expired }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Brim/0.2 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300:
            guard let windows = ClaudeUsageResponse.parse(data) else { throw ClaudeUsageError.unexpected }
            return windows
        case 401, 403: throw ClaudeUsageError.rejected
        case let code: throw ClaudeUsageError.http(code)
        }
    }

    /// Claude Code's own Keychain item for the account's folder. Read with `/usr/bin/security`,
    /// as Claude Code does, so macOS doesn't ask the user to approve Brim for the item.
    public static func credentials(for account: ClaudeAccount) -> ClaudeCredentials? {
        let user = ProcessInfo.processInfo.environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
        for service in account.keychainServices {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-a", user, "-s", service, "-w"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            do { try process.run() } catch { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0, let credentials = ClaudeCredentials.parse(data) { return credentials }
        }
        return nil
    }
}

// MARK: - Adding an account

public enum ClaudeAccountSetupError: LocalizedError, Equatable {
    case notInstalled
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "Claude Code isn't installed on this Mac. Install it from claude.com/claude-code, then try again."
        case .cancelled: return "Sign-in cancelled."
        case .failed(let reason): return reason
        }
    }
}

/// Signs another Claude account in to its own Claude Code config folder, using Claude Code's own
/// `claude auth login`: it opens the browser, waits for the sign-in and stores the token in the
/// Keychain itself. Brim never sees the password or the token. `~/.claude` is never touched.
public enum ClaudeAccountSetup {
    /// Creates `~/.claude-<label>`, signs in there and returns the new account. `onSignInURL` gets
    /// the sign-in page in case the browser didn't open. Cancelling the task stops the sign-in
    /// and removes the folder.
    public static func addAccount(label: String,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  timeout: TimeInterval = 600,
                                  onSignInURL: @escaping @Sendable (URL) -> Void = { _ in }) async throws -> ClaudeAccount {
        guard let claude = ClaudeCode.executable(home: home) else { throw ClaudeAccountSetupError.notInstalled }
        let configDir = ClaudeAccounts.newConfigDir(label: label, home: home)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        do {
            let status = try await signIn(claude: claude, configDir: configDir, timeout: timeout, onSignInURL: onSignInURL)
            guard status == 0 else { throw ClaudeAccountSetupError.failed("Claude Code couldn't finish signing in. Try again.") }
            let account = signedInAccount(claude: claude, configDir: configDir, home: home)
            guard account.isSignedIn else { throw ClaudeAccountSetupError.failed("Claude Code didn't report a signed-in account.") }
            return account
        } catch {
            if !ClaudeAccounts.account(configDir: configDir, home: home).isSignedIn {
                try? FileManager.default.removeItem(at: configDir)
            }
            throw Task.isCancelled ? ClaudeAccountSetupError.cancelled : error
        }
    }

    private final class LoginState: @unchecked Sendable {
        let lock = NSLock()
        var buffer = ""
        var reportedURL = false
    }

    private static func signIn(claude: URL, configDir: URL, timeout: TimeInterval,
                               onSignInURL: @escaping @Sendable (URL) -> Void) async throws -> Int32 {
        let process = ClaudeCode.process(["auth", "login", "--claudeai"], configDir: configDir, executable: claude)
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let state = LoginState()
        output.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            state.lock.lock()
            defer { state.lock.unlock() }
            guard !state.reportedURL else { return }
            state.buffer += text
            if let url = signInURL(in: state.buffer) {
                state.reportedURL = true
                onSignInURL(url)
            }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: ClaudeAccountSetupError.failed("Couldn't start Claude Code."))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// The first `https://` URL after "visit:" in `claude auth login`'s output.
    static func signInURL(in text: String) -> URL? {
        guard let range = text.range(of: "visit: ") else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(where: { $0.isWhitespace }) else { return nil }
        let candidate = String(rest[..<end])
        return candidate.hasPrefix("https://") ? URL(string: candidate) : nil
    }

    /// The account from the folder's `.claude.json`, or from `claude auth status --json` when the
    /// profile hasn't been written yet.
    static func signedInAccount(claude: URL, configDir: URL, home: URL) -> ClaudeAccount {
        let account = ClaudeAccounts.account(configDir: configDir, home: home)
        if account.isSignedIn { return account }
        let process = ClaudeCode.process(["auth", "status", "--json"], configDir: configDir, executable: claude)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return account }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let status = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], status["loggedIn"] as? Bool == true else {
            return account
        }
        let subscription = (status["subscriptionType"] as? String).map { "claude_\($0)" }
        return ClaudeAccount(configDir: configDir, isDefault: false, email: status["email"] as? String,
                             organizationType: subscription, rateLimitTier: nil)
    }
}

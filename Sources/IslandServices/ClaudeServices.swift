import Foundation
import IslandCore
import Security

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
        case .expired: return "Sign-in expired and couldn't be renewed. Open Claude Code once to refresh."
        case .rejected: return "Claude didn't accept the sign-in. Open Claude Code once to refresh."
        case .http(let code): return "Claude's usage service returned an error (HTTP \(code))."
        case .unexpected: return "Claude's usage service answered in a format Brim doesn't understand yet."
        }
    }
}

/// Reads an account's plan limits from Anthropic, the same request Claude Code's `/usage` makes.
///
/// Uses the OAuth tokens Claude Code keeps in the Keychain. When the ~8h access token is stale,
/// Brim refreshes it the same way Claude Code does (`POST https://platform.claude.com/v1/oauth/token`
/// with Claude Code's public client id) and writes the rotated tokens back to that Keychain item
/// so Claude Code stays in sync. Brim therefore **mutates Claude Code's Keychain item** (same
/// service/account names Claude Code uses). Usage itself is still only requested from
/// `api.anthropic.com`. Tokens are never logged and never passed on process argv.
public enum ClaudeUsageFetcher {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage?at_wall=1&skip_spend=1")!
    /// Claude Code's current OAuth token endpoint (not api.anthropic.com — that host serves usage/profile).
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Claude Code's public native OAuth client id.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// Serializes refresh single-flight bookkeeping off the async executor (NSLock isn't async-safe).
    private static let refreshGate = DispatchQueue(label: "com.brim.claude-oauth-refresh")
    private static var refreshWaiters: [String: [CheckedContinuation<Result<ClaudeCredentials, Error>, Never>]] = [:]

    public static func fetch(_ account: ClaudeAccount, now: Date = Date()) async throws -> [PlanWindow] {
        let stored = try await validCredentials(for: account, now: now)
        do {
            return try await requestUsage(accessToken: stored.accessToken)
        } catch ClaudeUsageError.rejected {
            // Access token rejected mid-life — refresh once and retry.
            let renewed = try await refreshCredentials(for: account, force: true)
            return try await requestUsage(accessToken: renewed.accessToken)
        }
    }

    /// Credentials that are usable now: refresh when the access token is past (or within 60s of) expiry.
    static func validCredentials(for account: ClaudeAccount, now: Date = Date()) async throws -> ClaudeCredentials {
        guard let item = ClaudeCodeKeychain.read(for: account) else { throw ClaudeUsageError.notSignedIn }
        if !item.credentials.isExpired(now: now) { return item.credentials }
        return try await refreshCredentials(for: account, force: false)
    }

    private static func requestUsage(accessToken: String) async throws -> [PlanWindow] {
        do { try TrustedHosts.validate(usageURL, policy: .allowlist) } catch { throw ClaudeUsageError.unexpected }
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
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

    /// Refreshes the account's OAuth tokens and writes them back to Claude Code's Keychain item.
    /// Concurrent callers for the same Keychain service share one in-flight refresh so two Brim
    /// timers can't rotate the same refresh token against each other.
    static func refreshCredentials(for account: ClaudeAccount, force: Bool) async throws -> ClaudeCredentials {
        guard let item = ClaudeCodeKeychain.read(for: account) else { throw ClaudeUsageError.notSignedIn }
        if !force, !item.credentials.isExpired() { return item.credentials }
        guard item.credentials.refreshToken != nil else { throw ClaudeUsageError.expired }

        let service = item.service
        return try await withCheckedContinuation { (continuation: CheckedContinuation<Result<ClaudeCredentials, Error>, Never>) in
            refreshGate.async {
                if refreshWaiters[service] != nil {
                    refreshWaiters[service, default: []].append(continuation)
                    return
                }
                refreshWaiters[service] = [continuation]
                Task {
                    let result: Result<ClaudeCredentials, Error>
                    do {
                        result = .success(try await performRefresh(account: account, service: service, force: force))
                    } catch {
                        result = .failure(error)
                    }
                    refreshGate.async {
                        let waiters = refreshWaiters.removeValue(forKey: service) ?? []
                        for waiter in waiters { waiter.resume(returning: result) }
                    }
                }
            }
        }.get()
    }

    private static func performRefresh(account: ClaudeAccount, service: String, force: Bool) async throws -> ClaudeCredentials {
        // Re-read under the single-flight so a concurrent Claude Code refresh wins without a fight.
        guard let latest = ClaudeCodeKeychain.read(service: service) ?? ClaudeCodeKeychain.read(for: account) else {
            throw ClaudeUsageError.notSignedIn
        }
        if !force, !latest.credentials.isExpired() { return latest.credentials }
        guard let refreshToken = latest.credentials.refreshToken else { throw ClaudeUsageError.expired }

        let tokens = try await requestTokenRefresh(refreshToken: refreshToken)
        guard let updatedJSON = ClaudeCredentialsJSON.applying(tokens, to: latest.raw) else {
            throw ClaudeUsageError.unexpected
        }
        // Refresh tokens rotate: write back before using, or Claude Code's copy goes stale.
        guard ClaudeCodeKeychain.write(service: latest.service, data: updatedJSON) else {
            throw ClaudeUsageError.expired
        }
        guard let credentials = ClaudeCredentials.parse(updatedJSON) else { throw ClaudeUsageError.unexpected }
        return credentials
    }

    /// Exchanges a refresh token the way Claude Code does. Response body is parsed then discarded;
    /// tokens are never logged.
    static func requestTokenRefresh(refreshToken: String) async throws -> ClaudeOAuthTokens {
        do { try TrustedHosts.validate(tokenURL, policy: .allowlist) } catch { throw ClaudeUsageError.unexpected }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Brim/0.2 (macOS)", forHTTPHeaderField: "User-Agent")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            guard let tokens = ClaudeOAuthTokens.parse(data) else { throw ClaudeUsageError.unexpected }
            return tokens
        case 400, 401, 403:
            throw ClaudeUsageError.expired
        default:
            throw ClaudeUsageError.http(status)
        }
    }

    /// Claude Code's own Keychain item for the account's folder.
    public static func credentials(for account: ClaudeAccount) -> ClaudeCredentials? {
        ClaudeCodeKeychain.read(for: account)?.credentials
    }
}

/// Read/write Claude Code's generic-password Keychain item.
///
/// **Write** always uses Security.framework (`SecItemUpdate` / `SecItemAdd`) so the credential
/// JSON never appears on process argv (`ps`, audit tools). Brim mutates the same service/account
/// names Claude Code uses so Claude Code stays signed in after a refresh.
/// **Read** tries Security.framework first, then `/usr/bin/security find-generic-password -w`
/// (print password to stdout — the secret is not on argv) for ACL parity with Claude Code.
enum ClaudeCodeKeychain {
    struct Item {
        var service: String
        var credentials: ClaudeCredentials
        var raw: Data
    }

    static var accountName: String {
        ProcessInfo.processInfo.environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
    }

    static func read(for account: ClaudeAccount) -> Item? {
        for service in account.keychainServices {
            if let item = read(service: service) { return item }
        }
        return nil
    }

    static func read(service: String) -> Item? {
        if let data = readViaSecurityFramework(service: service),
           let credentials = ClaudeCredentials.parse(data) {
            return Item(service: service, credentials: credentials, raw: data)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        // `-w` on find-generic-password means "print password to stdout", not "password follows".
        process.arguments = ["find-generic-password", "-a", accountName, "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let credentials = ClaudeCredentials.parse(data) else { return nil }
        return Item(service: service, credentials: credentials, raw: data)
    }

    /// Updates the existing item in-process. Returns false if the write fails — caller must not
    /// keep using a rotated refresh token that never made it to the Keychain.
    ///
    /// Never shells out with `-w <password>`: that put the full OAuth JSON on process argv.
    static func write(service: String, data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountName,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var item: [String: Any] = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func readViaSecurityFramework(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
}

private extension Result {
    func get() throws -> Success {
        switch self {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}

// MARK: - Adding an account

public enum ClaudeAccountSetupError: LocalizedError, Equatable {
    case notInstalled
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "To finish Claude sign-in, install Claude Code once from claude.com/claude-code (Brim uses its browser sign-in; you don't need the Terminal)."
        case .cancelled: return "Sign-in cancelled."
        case .failed(let reason): return reason
        }
    }
}

/// Signs a Claude account in via Anthropic's browser OAuth (`claude auth login --claudeai`).
/// Opens the browser, waits for the sign-in, and lets Claude Code store the token in the Keychain.
/// Brim never sees the password or the token. Uses a separate config folder so accounts don't mix;
/// `~/.claude` is never touched. Plan limits come from Anthropic's usage API after sign-in.
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

import Foundation
import IslandCore
import Security
import SQLite3

// MARK: - Errors

public enum ConnectorError: LocalizedError {
    case needsToken(String)
    case unauthorized(String)
    case unexpectedResponse(String)
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .needsToken(let help): return help
        case .unauthorized(let help): return help
        case .unexpectedResponse(let what): return "\(what) answered in a format Brim doesn't understand yet."
        case .http(let code): return "The service returned an error (HTTP \(code)). Try again later."
        }
    }
}

// MARK: - Account fetchers

/// Fetches plan and allowance usage for account-based connections. Credentials come from a token
/// the user saved for the connection (Keychain) or, when there is none, from the tool's own
/// sign-in on this Mac. Nothing is sent anywhere except the tool's own service.
public enum AccountFetcher {
    public static func fetch(_ connection: Connection) async throws -> AccountUsage {
        let saved = Keychain.read(connection.id)
        switch connection.kind {
        case .copilot:
            let login = connection.option(Connection.Option.githubLogin)
            guard let token = saved ?? GitHubCLI.token(user: login) else {
                throw ConnectorError.needsToken(login.isEmpty ? tokenHelp(for: .copilot)
                    : "The GitHub CLI isn't signed in to \(login) anymore. Sign in with GitHub again, or paste a token.")
            }
            return try await copilot(token: token)
        case .cursor:
            var usage = try await cursor(token: saved ?? VSCodeState.value(app: "Cursor", key: "cursorAuth/accessToken"))
            // Only Cursor's own sign-in says whose it is; a pasted token may be another account.
            if saved == nil { usage.accountLabel = VSCodeState.value(app: "Cursor", key: "cursorAuth/cachedEmail") }
            return usage
        case .windsurf: return try await windsurf(apiKey: saved ?? VSCodeState.windsurfAPIKey())
        case .openrouter: return try await openRouter(key: saved)
        case .customEndpoint: return try await endpoint(connection, token: saved)
        case .claude, .codex, .customLogs:
            throw ConnectorError.unexpectedResponse(connection.kind.displayName)
        }
    }

    /// What to tell people when no credential was found.
    public static func tokenHelp(for kind: ToolKind) -> String {
        switch kind {
        case .copilot: return "Sign in with GitHub, or paste a GitHub token."
        case .cursor: return "Sign in to the Cursor app on this Mac, or paste your Cursor session token."
        case .windsurf: return "Sign in to the Windsurf app on this Mac, or paste your Windsurf API key."
        case .openrouter: return "Paste an OpenRouter API key (openrouter.ai/keys)."
        case .customEndpoint: return "Set the URL, and a token if the endpoint needs one."
        default: return ""
        }
    }

    /// Whether the connection can work without the user pasting anything.
    public static func canAutoConnect(_ kind: ToolKind) -> Bool {
        kind == .copilot || kind == .cursor || kind == .windsurf
    }

    // MARK: Services

    private static func copilot(token: String) async throws -> AccountUsage {
        var request = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode/1.99.0", forHTTPHeaderField: "Editor-Version")
        let data = try await send(request, service: "GitHub", help: "GitHub didn't accept the sign-in. Sign in with GitHub again, or paste a new token.")
        if CopilotUsage.lacksCopilot(data) {
            throw ConnectorError.unauthorized("This GitHub account doesn't have Copilot. Turn on Copilot Free at github.com/settings/copilot, or sign in with another account.")
        }
        guard let usage = CopilotUsage.parse(data) else { throw ConnectorError.unexpectedResponse("GitHub Copilot") }
        return usage
    }

    private static func cursor(token: String?) async throws -> AccountUsage {
        guard let token, !token.isEmpty else { throw ConnectorError.needsToken(tokenHelp(for: .cursor)) }
        // A pasted session cookie looks like `user_123%3A%3A<jwt>`; the app's own token is just the JWT.
        let cookieValue: String
        let userID: String?
        if let range = token.range(of: "%3A%3A") ?? token.range(of: "::") {
            userID = String(token[..<range.lowerBound])
            cookieValue = token.replacingOccurrences(of: "::", with: "%3A%3A")
        } else {
            userID = CursorUsage.userID(fromAccessToken: token)
            cookieValue = "\(userID ?? "")%3A%3A\(token)"
        }
        guard let userID, !userID.isEmpty else { throw ConnectorError.needsToken(tokenHelp(for: .cursor)) }
        let help = "Cursor didn't accept the sign-in. Open Cursor and sign in again."
        let membership = VSCodeState.value(app: "Cursor", key: "cursorAuth/stripeMembershipType")

        var summary = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        summary.setValue("WorkosCursorSessionToken=\(cookieValue)", forHTTPHeaderField: "Cookie")
        if let data = try? await send(summary, service: "Cursor", help: help), var usage = CursorUsage.parseSummary(data) {
            if usage.planName == nil, let membership { usage.planName = membership.capitalized }
            return usage
        }

        var legacy = URLRequest(url: URL(string: "https://cursor.com/api/usage?user=\(userID)")!)
        legacy.setValue("WorkosCursorSessionToken=\(cookieValue)", forHTTPHeaderField: "Cookie")
        let data = try await send(legacy, service: "Cursor", help: help)
        guard let usage = CursorUsage.parseRequests(data, membership: membership) else { throw ConnectorError.unexpectedResponse("Cursor") }
        return usage
    }

    private static func windsurf(apiKey: String?) async throws -> AccountUsage {
        guard let apiKey, !apiKey.isEmpty else { throw ConnectorError.needsToken(tokenHelp(for: .windsurf)) }
        var request = URLRequest(url: URL(string: "https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["metadata": [
            "apiKey": apiKey, "ideName": "windsurf", "ideVersion": "1.0.0",
            "extensionName": "windsurf", "extensionVersion": "1.0.0", "locale": "en",
        ]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request, service: "Windsurf", help: "Windsurf didn't accept the sign-in. Open Windsurf and sign in again.")
        guard let usage = WindsurfUsage.parse(data) else { throw ConnectorError.unexpectedResponse("Windsurf") }
        return usage
    }

    private static func openRouter(key: String?) async throws -> AccountUsage {
        guard let key, !key.isEmpty else { throw ConnectorError.needsToken(tokenHelp(for: .openrouter)) }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let data = try await send(request, service: "OpenRouter", help: "OpenRouter didn't accept the API key. Paste a new one.")
        guard let usage = EndpointUsage.openRouter.parse(data) else { throw ConnectorError.unexpectedResponse("OpenRouter") }
        return usage
    }

    private static func endpoint(_ connection: Connection, token: String?) async throws -> AccountUsage {
        typealias O = Connection.Option
        guard let url = URL(string: connection.option(O.url)), url.scheme == "https" || url.scheme == "http" else {
            throw ConnectorError.needsToken("Set the usage URL (https://…) for \(connection.name).")
        }
        var request = URLRequest(url: url)
        let header = connection.option(O.authHeader)
        if let token, !token.isEmpty, !header.isEmpty {
            request.setValue((connection.options[O.authPrefix] ?? "") + token, forHTTPHeaderField: header)
        }
        let data = try await send(request, service: connection.name, help: "\(connection.name) didn't accept the token.")
        let reader = EndpointUsage(
            usedPath: connection.option(O.usedPath), limitPath: connection.option(O.limitPath),
            planPath: connection.option(O.planPath), resetPath: connection.option(O.resetPath),
            label: connection.option(O.label).isEmpty ? "Usage" : connection.option(O.label)
        )
        guard let usage = reader.parse(data) else {
            throw ConnectorError.unexpectedResponse("\(connection.name) (check the JSON paths)")
        }
        return usage
    }

    private static func send(_ request: URLRequest, service: String, help: String) async throws -> Data {
        var request = request
        request.timeoutInterval = 20
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("Brim/0.2 (macOS)", forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401, 403: throw ConnectorError.unauthorized(help)
        default: throw ConnectorError.http(status)
        }
    }
}

// MARK: - Local credentials

/// Reads the GitHub CLI's sign-ins, if the CLI is installed. `gh` can hold several github.com
/// accounts; Brim reads any of them by login, so it never has to switch the active one.
public enum GitHubCLI {
    public static var isInstalled: Bool { executable != nil }

    /// The token of `user`, or of the active account when `user` is nil or empty.
    public static func token(user: String? = nil) -> String? {
        var arguments = ["auth", "token", "--hostname", "github.com"]
        if let user, !user.isEmpty { arguments += ["--user", user] }
        guard let token = run(arguments)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return token.isEmpty ? nil : token
    }

    /// The github.com accounts `gh` is signed in to, active first.
    public static func accounts() -> [GitHubAccount] {
        guard let output = run(["auth", "status", "--hostname", "github.com", "--json", "hosts"]) else { return [] }
        return GitHubAccount.parseStatus(Data(output.utf8))
    }

    private static var executable: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first(where: FileManager.default.isExecutableFile(atPath:))
    }

    private static func run(_ arguments: [String]) -> String? {
        guard let path = executable else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Signs in to GitHub in the browser with OAuth's device flow: Brim shows a short code, the user
/// enters it on github.com, and Brim receives a token for that account.
public enum GitHubDeviceFlow {
    /// The GitHub CLI's public OAuth app, so the sign-in matches what `gh auth login` grants.
    static let clientID = "178c6fc778ccc68e1d6a"

    public struct Code: Equatable, Sendable {
        public var userCode: String
        public var verificationURL: URL
        var deviceCode: String
        var interval: TimeInterval
        var expiresAt: Date
    }

    public enum Failure: LocalizedError {
        case expired, denied, unexpected
        public var errorDescription: String? {
            switch self {
            case .expired: return "The code expired. Start again to get a new one."
            case .denied: return "GitHub sign-in was cancelled."
            case .unexpected: return "GitHub answered in a format Brim doesn't understand yet."
            }
        }
    }

    public static func start() async throws -> Code {
        let root = try await post("https://github.com/login/device/code", ["client_id": clientID, "scope": "read:user"])
        guard let deviceCode = root["device_code"] as? String, let userCode = root["user_code"] as? String,
              let uri = (root["verification_uri"] as? String).flatMap(URL.init(string:))
        else { throw Failure.unexpected }
        let expiresIn = (root["expires_in"] as? NSNumber)?.doubleValue ?? 900
        return Code(userCode: userCode, verificationURL: uri, deviceCode: deviceCode,
                    interval: max(5, (root["interval"] as? NSNumber)?.doubleValue ?? 5), expiresAt: Date().addingTimeInterval(expiresIn))
    }

    /// Waits until the user approves the code on github.com and returns the token.
    public static func token(for code: Code) async throws -> String {
        var interval = code.interval
        while Date() < code.expiresAt {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            let root = try await post("https://github.com/login/oauth/access_token", [
                "client_id": clientID, "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let token = root["access_token"] as? String, !token.isEmpty { return token }
            switch root["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "expired_token": throw Failure.expired
            case "access_denied": throw Failure.denied
            default: throw Failure.unexpected
            }
        }
        throw Failure.expired
    }

    private static func post(_ url: String, _ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+:")
        request.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw Failure.unexpected }
        return root
    }
}

/// Reads values from a VS Code-based editor's local state database (Cursor, Windsurf), read-only.
public enum VSCodeState {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public static func value(app: String, key: String) -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(app)/User/globalStorage/state.vscdb").path
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        var db: OpaquePointer?
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard sqlite3_open_v2("file:\(encoded)?mode=ro&immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }

        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        var text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        return text.isEmpty ? nil : text
    }

    public static func windsurfAPIKey() -> String? {
        guard let raw = value(app: "Windsurf", key: "windsurfAuthStatus"),
              let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return object["apiKey"] as? String
    }
}

/// Tokens the user pasted, one Keychain item per connection.
public enum Keychain {
    public static let service = "com.brim.app.connections"
    /// Where AI Island, Brim's old name, kept the same tokens.
    static let legacyService = "com.aiisland.app.connections"

    public static func read(_ account: String, service: String = service) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func save(_ value: String, for account: String) {
        delete(account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    public static func delete(_ account: String, service: String = service) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    public static func has(_ account: String) -> Bool {
        read(account) != nil
    }

    /// Moves tokens saved under the old service name to the current one.
    public static func migrateLegacy(accounts: [String]) {
        for account in accounts {
            guard let token = read(account, service: legacyService) else { continue }
            if read(account) == nil { save(token, for: account) }
            delete(account, service: legacyService)
        }
    }
}

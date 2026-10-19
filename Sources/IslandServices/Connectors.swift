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
        case .unexpectedResponse(let what): return "\(what) answered in a format AI Island doesn't understand yet."
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
        case .copilot: return try await copilot(token: saved ?? GitHubCLI.token())
        case .cursor: return try await cursor(token: saved ?? VSCodeState.value(app: "Cursor", key: "cursorAuth/accessToken"))
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
        case .copilot: return "Sign in with the GitHub CLI (gh auth login), or paste a GitHub token."
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

    private static func copilot(token: String?) async throws -> AccountUsage {
        guard let token else { throw ConnectorError.needsToken(tokenHelp(for: .copilot)) }
        var request = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode/1.99.0", forHTTPHeaderField: "Editor-Version")
        let data = try await send(request, service: "GitHub", help: "GitHub didn't accept the token. Run gh auth login again, or paste a new token.")
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
            request.setValue("AIIsland/0.2 (macOS)", forHTTPHeaderField: "User-Agent")
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

/// Reads the GitHub CLI's token, if the CLI is installed and signed in.
public enum GitHubCLI {
    public static func token() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["auth", "token"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let token = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
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
    private static let service = "com.aiisland.app.connections"

    public static func read(_ account: String) -> String? {
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

    public static func delete(_ account: String) {
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
}

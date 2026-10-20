import Foundation

/// Connects Brim as Claude Code's status line command, which is how Claude Code hands plan
/// usage (5-hour and weekly windows) to other programs.
///
/// Only the `statusLine` entry of Claude Code's `settings.json` is changed, a backup is written
/// first, and a status line the user already had keeps working: the bridge script saves the input
/// for Brim and then runs the previous command with the same input.
public struct ClaudeStatusLineSetup: Sendable {
    public enum State: Equatable {
        case notConnected
        case connected
        case unreadable
    }

    public enum SetupError: Error, LocalizedError {
        case unreadableSettings

        public var errorDescription: String? {
            "Claude Code's settings.json could not be read. Fix or remove it, then try again."
        }
    }

    public static let marker = "brim-statusline"

    /// Brim's own folder, e.g. `~/Library/Application Support/Brim`.
    public let supportDirectory: URL
    /// Claude Code's `settings.json`.
    public let settingsURL: URL

    public init(supportDirectory: URL, settingsURL: URL) {
        self.supportDirectory = supportDirectory
        self.settingsURL = settingsURL
    }

    public static func defaultSettingsURL(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                          environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["CLAUDE_CONFIG_DIR"]?.split(separator: ",").first, !custom.isEmpty {
            return URL(fileURLWithPath: String(custom)).appendingPathComponent("settings.json")
        }
        return home.appendingPathComponent(".claude/settings.json")
    }

    /// Brim's support folder, shared by the app and the CLI.
    public static var defaultSupportDirectory: URL {
        LegacyMigration.applicationSupport.appendingPathComponent(LegacyMigration.supportFolder, isDirectory: true)
    }

    public var scriptURL: URL { supportDirectory.appendingPathComponent("\(Self.marker).sh") }
    /// The last status line input Claude Code sent (overwritten on every update).
    public var dataURL: URL { supportDirectory.appendingPathComponent("claude-statusline.json") }
    private var previousCommandURL: URL { supportDirectory.appendingPathComponent("claude-statusline.previous") }
    private var previousEntryURL: URL { supportDirectory.appendingPathComponent("claude-statusline.previous.json") }

    public func state() -> State {
        guard let settings = readSettings() else { return .unreadable }
        return Self.isOurs(settings["statusLine"]) ? .connected : .notConnected
    }

    /// The latest plan windows, or none when not connected or nothing was reported yet.
    public func planWindows() -> [PlanWindow] {
        guard let data = try? Data(contentsOf: dataURL) else { return [] }
        return ClaudeStatusLine.planWindows(from: data)
    }

    public func connect() throws {
        guard var settings = readSettings() else { throw SetupError.unreadableSettings }
        let fm = FileManager.default
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        if !Self.isOurs(settings["statusLine"]) {
            // Remember the user's own status line so it keeps working and can be put back.
            if let previous = settings["statusLine"] as? [String: Any] {
                let data = try JSONSerialization.data(withJSONObject: previous)
                try data.write(to: previousEntryURL, options: .atomic)
                let command = (previous["command"] as? String) ?? ""
                try Data(command.utf8).write(to: previousCommandURL, options: .atomic)
            } else {
                try? fm.removeItem(at: previousEntryURL)
                try? fm.removeItem(at: previousCommandURL)
            }
        }

        try Data(bridgeScript.utf8).write(to: scriptURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        settings["statusLine"] = [
            "type": "command",
            "command": "'\(scriptURL.path.replacingOccurrences(of: "'", with: "'\\''"))'",
        ]
        try writeSettings(settings)
    }

    public func disconnect() throws {
        guard var settings = readSettings() else { throw SetupError.unreadableSettings }
        guard Self.isOurs(settings["statusLine"]) else { return }

        if let data = try? Data(contentsOf: previousEntryURL),
           let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings["statusLine"] = previous
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        try writeSettings(settings)
        try? FileManager.default.removeItem(at: previousEntryURL)
        try? FileManager.default.removeItem(at: previousCommandURL)
        try? FileManager.default.removeItem(at: dataURL)
    }

    static func isOurs(_ entry: Any?) -> Bool {
        guard let command = (entry as? [String: Any])?["command"] as? String else { return false }
        return command.contains(marker) || command.contains(LegacyMigration.legacyMarker)
    }

    /// Points Claude Code at this folder's bridge again when it still runs one from an old location
    /// (AI Island's folder, before the rename). Returns true when it changed anything.
    @discardableResult
    public func repairIfMoved() throws -> Bool {
        guard let settings = readSettings(), Self.isOurs(settings["statusLine"]),
              let command = (settings["statusLine"] as? [String: Any])?["command"] as? String,
              !command.contains(scriptURL.path)
        else { return false }
        try connect()
        try? FileManager.default.removeItem(at: supportDirectory.appendingPathComponent("\(LegacyMigration.legacyMarker).sh"))
        return true
    }

    /// Settings as a dictionary; an empty one when the file does not exist yet, nil when unreadable.
    private func readSettings() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        return JSON.object(data)
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.appendingPathExtension("brim-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    var bridgeScript: String {
        let dir = supportDirectory.path.replacingOccurrences(of: "'", with: "'\\''")
        return """
        #!/bin/sh
        # Installed by Brim. Saves only the rate_limits Brim needs (not the full Claude Code
        # status-line stdin, which can include paths and session metadata), then runs your
        # previous status line command (if any) with the original input.
        DIR='\(dir)'
        INPUT=$(cat)
        mkdir -p "$DIR"
        umask 077
        RAW="$(mktemp -t brim-statusline)"
        trap 'rm -f "$RAW" "$DIR/claude-statusline.limits.tmp" "$DIR/claude-statusline.json.tmp"' EXIT
        chmod 600 "$RAW"
        printf '%s' "$INPUT" > "$RAW"
        TMP="$DIR/claude-statusline.json.tmp"
        if plutil -extract rate_limits json -o "$DIR/claude-statusline.limits.tmp" "$RAW" 2>/dev/null; then
          printf '{"rate_limits":' > "$TMP"
          cat "$DIR/claude-statusline.limits.tmp" >> "$TMP"
          printf '}' >> "$TMP"
        else
          printf '{"rate_limits":{}}' > "$TMP"
        fi
        chmod 600 "$TMP"
        mv -f "$TMP" "$DIR/claude-statusline.json"
        rm -f "$RAW" "$DIR/claude-statusline.limits.tmp"
        trap - EXIT
        if [ -s "$DIR/claude-statusline.previous" ]; then
          printf '%s' "$INPUT" | sh -c "$(cat "$DIR/claude-statusline.previous")"
        fi

        """
    }
}

import Foundation

/// A tool that looks installed or signed in on this Mac, for first-run and `brim detect`.
public struct DetectedTool: Equatable, Sendable, Identifiable {
    public var id: String { kind.rawValue }
    public let kind: ToolKind
    /// Path or short reason shown under the name (for example `~/.claude/projects`).
    public let detail: String
    /// True when logs (or a sign-in) look used in the last 30 days. Found log tools start checked only then.
    public let recentlyActive: Bool
    /// Account tools that need a browser / CLI sign-in rather than a local log folder.
    public let needsSignIn: Bool

    public init(kind: ToolKind, detail: String, recentlyActive: Bool, needsSignIn: Bool = false) {
        self.kind = kind
        self.detail = detail
        self.recentlyActive = recentlyActive
        self.needsSignIn = needsSignIn
    }

    public var shouldPreCheck: Bool { !needsSignIn && recentlyActive }
}

/// Local file checks only — no network, nothing opened beyond listing directories.
public enum ToolDetection {
    public static let activityWindow: TimeInterval = 30 * 24 * 60 * 60

    /// Claude Code and Codex when their default log folders exist.
    public static func logTools(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                environment: [String: String] = ProcessInfo.processInfo.environment,
                                now: Date = Date(),
                                fileManager: FileManager = .default) -> [DetectedTool] {
        var found: [DetectedTool] = []
        if let hit = firstExisting(DefaultLogLocations.roots(for: .claude, home: home, environment: environment),
                                   fileManager: fileManager) {
            let active = newestModification(under: hit, fileManager: fileManager)
                .map { now.timeIntervalSince($0) < activityWindow } ?? false
            found.append(DetectedTool(kind: .claude, detail: displayPath(hit, home: home),
                                      recentlyActive: active))
        }
        if let hit = firstExisting(DefaultLogLocations.roots(for: .codex, home: home, environment: environment),
                                   fileManager: fileManager) {
            let active = newestModification(under: hit, fileManager: fileManager)
                .map { now.timeIntervalSince($0) < activityWindow } ?? false
            found.append(DetectedTool(kind: .codex, detail: displayPath(hit, home: home),
                                      recentlyActive: active))
        }
        return found
    }

    private static func firstExisting(_ urls: [URL], fileManager: FileManager) -> URL? {
        urls.first { fileManager.fileExists(atPath: $0.path) }
    }

    private static func newestModification(under root: URL, fileManager: FileManager) -> Date? {
        var newest: Date?
        guard let enumerator = fileManager.enumerator(at: root,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return nil }
        let deadline = Date().addingTimeInterval(0.4)
        while let next = enumerator.nextObject() as? URL {
            if Date() > deadline { break }
            guard let values = try? next.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let date = values.contentModificationDate else { continue }
            if newest == nil || date > newest! { newest = date }
        }
        return newest
    }

    public static func displayPath(_ url: URL, home: URL) -> String {
        let path = url.path
        if path.hasPrefix(home.path) {
            return "~" + path.dropFirst(home.path.count)
        }
        return path
    }
}

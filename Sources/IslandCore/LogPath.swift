import Foundation

/// Safe resolution for user-supplied log folders: no symlink escape from the configured root,
/// and custom roots must stay under the user's home directory.
public enum LogPath {
    /// Expands `~`, standardizes, resolves symlinks, and rejects paths that leave `home`.
    /// Returns nil when the path is empty, escapes home after resolution, or cannot be resolved.
    public static func sanitizeRoot(_ raw: String,
                                    home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded: String
        if trimmed == "~" {
            expanded = home.path
        } else if trimmed.hasPrefix("~/") {
            expanded = home.path + "/" + trimmed.dropFirst(2)
        } else {
            expanded = trimmed
        }
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard isInside(resolved, home: home) else { return nil }
        return resolved
    }

    /// Whether `url` is `home` or a descendant after resolving both sides' symlinks.
    public static func isInside(_ url: URL, home: URL) -> Bool {
        let homePath = normalize(home.resolvingSymlinksInPath().standardizedFileURL.path)
        let path = normalize(url.resolvingSymlinksInPath().standardizedFileURL.path)
        return path == homePath || path.hasPrefix(homePath + "/")
    }

    /// Whether `file` still lies under `root` after resolving symlinks (blocks symlink escape).
    public static func isUnderRoot(_ file: URL, root: URL) -> Bool {
        let rootPath = normalize(root.resolvingSymlinksInPath().standardizedFileURL.path)
        let filePath = normalize(file.resolvingSymlinksInPath().standardizedFileURL.path)
        return filePath == rootPath || filePath.hasPrefix(rootPath + "/")
    }

    private static func normalize(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

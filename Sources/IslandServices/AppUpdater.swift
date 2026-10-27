import Foundation
import IslandCore

/// First-party updater: talks only to GitHub Releases for `abhargava14/brim`.
public enum AppUpdater {
    public static let owner = "abhargava14"
    public static let repo = "brim"
    public static let applicationsApp = URL(fileURLWithPath: "/Applications/Brim.app")

    public enum Outcome: Equatable {
        case upToDate(current: String, latest: String)
        case updateAvailable(Update)
        case aheadOfRelease(current: String, latest: String)
        case noReleaseAsset(tag: String)
    }

    public struct Update: Equatable {
        public let tag: String
        public let version: String
        public let dmgURL: URL
        public let sha256URL: URL?
        public let releaseNotes: String?

        public init(tag: String, version: String, dmgURL: URL, sha256URL: URL?, releaseNotes: String?) {
            self.tag = tag
            self.version = version
            self.dmgURL = dmgURL
            self.sha256URL = sha256URL
            self.releaseNotes = releaseNotes
        }
    }

    public enum Error: LocalizedError {
        case badURL
        case http(Int)
        case decode
        case untrustedHost(String)
        case checksumMissing
        case checksumMismatch
        case downloadFailed(String)
        case installFailed(String)

        public var errorDescription: String? {
            switch self {
            case .badURL: return "Couldn't build the GitHub Releases URL."
            case .http(let code): return "GitHub returned HTTP \(code)."
            case .decode: return "Couldn't read the GitHub release JSON."
            case .untrustedHost(let host): return "Refusing to download from untrusted host \(host)."
            case .checksumMissing: return "Release has no .sha256 asset; refusing to install without a checksum."
            case .checksumMismatch: return "Downloaded DMG failed SHA-256 verification."
            case .downloadFailed(let message): return message
            case .installFailed(let message): return message
            }
        }
    }

    /// Version of the running build: Info.plist when inside Brim.app, else `BrimVersion.string`.
    public static func currentVersion() -> String {
        if let bundle = Bundle.main.infoDictionary,
           let short = bundle["CFBundleShortVersionString"] as? String,
           !short.isEmpty {
            return short
        }
        return BrimVersion.string
    }

    /// Where to install: `/Applications/Brim.app` when that (or this) bundle is the install target.
    public static func installDestination() -> URL {
        let running = Bundle.main.bundleURL
        if running.path.hasSuffix(".app") {
            if running.standardizedFileURL == applicationsApp.standardizedFileURL
                || running.path.hasPrefix("/Applications/") {
                return applicationsApp
            }
            return running
        }
        return applicationsApp
    }

    // MARK: - Check

    public static func check(session: URLSession = .shared) async throws -> Outcome {
        let release = try await fetchLatestRelease(session: session)
        let version = normalizeVersion(release.tagName)
        guard let dmg = pickDMG(from: release.assets) else {
            return .noReleaseAsset(tag: release.tagName)
        }
        let sha = pickSHA256(from: release.assets, forDMG: dmg.name)
        let update = Update(
            tag: release.tagName,
            version: version,
            dmgURL: dmg.browserDownloadURL,
            sha256URL: sha?.browserDownloadURL,
            releaseNotes: release.body
        )
        let current = currentVersion()
        switch BrimVersion.compare(current, version) {
        case .orderedAscending:
            return .updateAvailable(update)
        case .orderedSame:
            return .upToDate(current: current, latest: version)
        case .orderedDescending:
            return .aheadOfRelease(current: current, latest: version)
        }
    }

    // MARK: - Download & install

    /// Downloads the DMG, verifies SHA-256 when a `.sha256` asset exists, and schedules replace + relaunch.
    /// Caller should quit Brim (or `exit`) shortly after this returns so the helper can replace the bundle.
    /// When `requireChecksum` is true and the release has no `.sha256` asset, install is refused.
    @discardableResult
    public static func downloadAndInstall(
        _ update: Update,
        destination: URL = installDestination(),
        session: URLSession = .shared,
        requireChecksum: Bool = false
    ) async throws -> URL {
        try assertTrusted(update.dmgURL)
        if let shaURL = update.sha256URL { try assertTrusted(shaURL) }
        else if requireChecksum { throw Error.checksumMissing }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("brim-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let dmgPath = temp.appendingPathComponent("Brim.dmg")
        try await download(update.dmgURL, to: dmgPath, session: session)

        if let shaURL = update.sha256URL {
            let expected = try await fetchExpectedSHA256(shaURL, session: session)
            let actual = try fileSHA256(dmgPath)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                throw Error.checksumMismatch
            }
        }

        let mountedApp = try attachAndFindApp(dmg: dmgPath, scratch: temp)
        // Live relaunch: first Refresh may unlock Keychain once for live plan % (Always Allow).
        PostUpdateLive.arm()
        try scheduleReplace(from: mountedApp, to: destination)
        return destination
    }

    // MARK: - Network

    private struct ReleaseDTO: Decodable {
        let tagName: String
        let body: String?
        let assets: [AssetDTO]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body, assets
        }
    }

    private struct AssetDTO: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    private static func fetchLatestRelease(session: URLSession) async throws -> ReleaseDTO {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            throw Error.badURL
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Brim/\(BrimVersion.string)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Error.http(code) }
        do {
            return try JSONDecoder().decode(ReleaseDTO.self, from: data)
        } catch {
            throw Error.decode
        }
    }

    private static func download(_ url: URL, to file: URL, session: URLSession) async throws {
        let (tempURL, response) = try await session.download(from: url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Error.http(code) }
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        try FileManager.default.moveItem(at: tempURL, to: file)
    }

    private static func fetchExpectedSHA256(_ url: URL, session: URLSession) async throws -> String {
        let (data, response) = try await session.data(from: url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Error.http(code) }
        let text = String(data: data, encoding: .utf8) ?? ""
        // `shasum -a 256` lines: "<hex>  <filename>" or just hex.
        let token = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).first.map(String.init) ?? ""
        let hex = token.lowercased().filter { $0.isHexDigit }
        guard hex.count == 64 else { throw Error.downloadFailed("Couldn't parse SHA-256 from \(url.lastPathComponent).") }
        return hex
    }

    // MARK: - Assets / trust

    private static func normalizeVersion(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    private static func pickDMG(from assets: [AssetDTO]) -> AssetDTO? {
        assets.first { $0.name.lowercased() == "brim.dmg" }
            ?? assets.first { $0.name.lowercased().hasSuffix(".dmg") }
    }

    private static func pickSHA256(from assets: [AssetDTO], forDMG name: String) -> AssetDTO? {
        let exact = name + ".sha256"
        if let match = assets.first(where: { $0.name == exact }) { return match }
        return assets.first { $0.name.lowercased().hasSuffix(".sha256") }
    }

    private static func assertTrusted(_ url: URL) throws {
        guard let host = url.host?.lowercased() else { throw Error.badURL }
        let allowed = ["api.github.com", "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]
        guard allowed.contains(host) || host.hasSuffix(".githubusercontent.com") else {
            throw Error.untrustedHost(host)
        }
        // Only this repo's release assets.
        if host == "github.com" || host == "api.github.com" {
            let path = url.path.lowercased()
            guard path.contains("/\(owner.lowercased())/\(repo.lowercased())/") else {
                throw Error.untrustedHost(host)
            }
        }
    }

    // MARK: - DMG attach / replace

    private static func attachAndFindApp(dmg: URL, scratch: URL) throws -> URL {
        let mount = scratch.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path]
        try run(attach, label: "hdiutil attach")
        let app = mount.appendingPathComponent("Brim.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            _ = try? detach(mount)
            throw Error.installFailed("Mounted DMG has no Brim.app.")
        }
        // Copy out so we can detach before replacing.
        let copy = scratch.appendingPathComponent("Brim.app")
        if FileManager.default.fileExists(atPath: copy.path) {
            try FileManager.default.removeItem(at: copy)
        }
        try FileManager.default.copyItem(at: app, to: copy)
        try detach(mount)
        return copy
    }

    private static func detach(_ mount: URL) throws {
        let detach = Process()
        detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detach.arguments = ["detach", mount.path, "-force"]
        try run(detach, label: "hdiutil detach")
    }

    private static func scheduleReplace(from sourceApp: URL, to destination: URL) throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("brim-apply-update-\(UUID().uuidString).sh")
        // Persist the staged app beside the script so cleanup of the download folder doesn't remove it.
        let staged = script.deletingLastPathComponent().appendingPathComponent("Brim-staged-\(UUID().uuidString).app")
        try FileManager.default.copyItem(at: sourceApp, to: staged)

        let dest = destination.path
        let src = staged.path
        let body = """
        #!/bin/bash
        set -euo pipefail
        # Wait until Brim is gone (up to ~30s).
        for _ in $(seq 1 60); do
          if ! pgrep -xq Brim && ! pgrep -xq AIIsland; then break; fi
          sleep 0.5
        done
        pkill -x Brim 2>/dev/null || true
        pkill -x AIIsland 2>/dev/null || true
        sleep 0.5
        rm -rf \(shellEscape(dest))
        mkdir -p "$(dirname \(shellEscape(dest)))"
        cp -R \(shellEscape(src)) \(shellEscape(dest))
        # Keep the release's own signature (a Developer ID one must never be replaced). Only a broken
        # signature is redone, the way build-app.sh signs: a fixed requirement so Keychain and privacy
        # approvals carry over to the new version. Never re-sign a valid release — that would change
        # the CDHash and force Keychain re-approval / login-password sheets.
        if ! codesign --verify --strict \(shellEscape(dest)) 2>/dev/null; then
          codesign --force --sign - -i com.brim.app -r='designated => identifier "com.brim.app"' \(shellEscape(dest))/Contents/Helpers/brim 2>/dev/null || true
          codesign --force --sign - -i com.brim.app -r='designated => identifier "com.brim.app"' \(shellEscape(dest)) 2>/dev/null || true
        fi
        # Relaunch: first account refresh may Keychain-prompt once for live plan % (Always Allow).
        open \(shellEscape(dest))
        rm -rf \(shellEscape(src))
        rm -f \(shellEscape(script.path))
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func run(_ process: Process, label: String) throws {
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Error.installFailed("\(label) failed\(message.isEmpty ? "" : ": \(message)").")
        }
    }

    private static func fileSHA256(_ file: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", file.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Error.checksumMismatch }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let hex = text.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
        guard hex.count == 64 else { throw Error.checksumMismatch }
        return hex
    }
}

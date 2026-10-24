import AppKit
import IslandCore
import IslandServices

/// Menu-driven update panel: check GitHub Releases, offer Download & Install.
@MainActor
enum BrimUpdateUI {
    static func check(from window: NSWindow?) async {
        do {
            let outcome = try await AppUpdater.check()
            present(outcome, from: window)
        } catch {
            let fail = NSAlert()
            fail.messageText = "Couldn't check for updates"
            fail.informativeText = error.localizedDescription
            fail.alertStyle = .warning
            fail.addButton(withTitle: "OK")
            run(fail, from: window)
        }
    }

    private static func present(_ outcome: AppUpdater.Outcome, from window: NSWindow?) {
        switch outcome {
        case .upToDate(let current, let latest):
            let alert = NSAlert()
            alert.messageText = "You’re up to date."
            alert.informativeText = "Brim \(current) matches the latest release (\(latest))."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            run(alert, from: window)

        case .aheadOfRelease(let current, let latest):
            let alert = NSAlert()
            alert.messageText = "Dev build ahead of latest release"
            alert.informativeText = "This Mac is running Brim \(current), which is newer than GitHub’s latest release (\(latest)). Quit alone never fetches builds — use Check for Updates when a newer release ships, or reinstall from source."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            run(alert, from: window)

        case .noReleaseAsset(let tag):
            let alert = NSAlert()
            alert.messageText = "No downloadable build"
            alert.informativeText = "Release \(tag) has no Brim.dmg asset yet. Install from source, or wait for a release that ships a DMG."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            run(alert, from: window)

        case .updateAvailable(let update):
            offer(update, from: window, watcher: nil)
        }
    }

    /// The "Update available" dialog, from a manual check, the notch notice or the menu.
    static func offer(_ update: AppUpdater.Update, from window: NSWindow? = nil, watcher: UpdateWatcher?) {
        let alert = NSAlert()
        alert.messageText = "Update available"
        alert.informativeText = """
        Brim \(update.version) (\(update.tag)) is ready.

        Download & Install will quit Brim, replace \(AppUpdater.installDestination().path), verify the SHA-256 when present, and relaunch.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download & Install")
        alert.addButton(withTitle: "Not Now")
        if watcher != nil { alert.addButton(withTitle: "Skip This Version") }
        let choice = run(alert, from: window)
        if choice == .alertThirdButtonReturn, let watcher { watcher.skip(update) }
        guard choice == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            await install(update, from: window)
        }
    }

    private static func install(_ update: AppUpdater.Update, from window: NSWindow?) async {
        do {
            _ = try await AppUpdater.downloadAndInstall(update)
            let done = NSAlert()
            done.messageText = "Installing…"
            done.informativeText = "Brim will quit and relaunch with the new build."
            done.alertStyle = .informational
            done.addButton(withTitle: "Quit & Install")
            _ = run(done, from: window)
            NSApp.terminate(nil)
        } catch {
            let fail = NSAlert()
            fail.messageText = "Update failed"
            fail.informativeText = error.localizedDescription
            fail.alertStyle = .critical
            fail.addButton(withTitle: "OK")
            run(fail, from: window)
        }
    }

    @discardableResult
    private static func run(_ alert: NSAlert, from window: NSWindow?) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        if let window, window.isVisible {
            return alert.runModal() // keep simple; sheet would need delegate plumbing
        }
        return alert.runModal()
    }
}

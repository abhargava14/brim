import AppKit
import Combine
import IslandCore
import IslandServices
import SwiftUI

@main
@MainActor
enum BrimMain {
    static func main() {
        BrimMigration.run()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // no Dock icon
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private lazy var model = UsageModel(settings: settings)
    private var island: IslandController?
    private var statusItem: NSStatusItem?
    private let setup = SetupWindows()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ClaudeAccountHook.install()
        // Collapse same-email Claude connections left over from older builds — and tell the user.
        let dedupe = settings.dedupeClaudeConnectionsByEmail()
        setUpStatusItem()
        island = IslandController(
            model: model, settings: settings, setup: setup,
            statusItemFrame: { [weak self] in self?.statusItem?.button?.window?.frame },
            openSettings: { [weak self] in self?.openSettings() },
            addAccount: { [weak self] in self?.openAddAccount($0) }
        )
        model.start()

        if dedupe.removedCount > 0 {
            // Once per launch when leftovers are collapsed — never silent delete.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                Self.reportCollapsedDuplicates(dedupe)
            }
        }

        // First run: pick tools found on this Mac, then how the island should look.
        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            openFirstRun()
        } else if ProcessInfo.processInfo.environment["BRIM_OPEN_APP"] == "1" {
            // Screenshot / QA hook: open the app shell once after launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.openSettings()
            }
        } else if ProcessInfo.processInfo.environment["BRIM_OPEN_ADD"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.openAddAccount(AddAccountRequest(kind: .claude))
            }
        }
    }

    /// Visible alert when launch dedupe removes duplicate Claude rows.
    private static func reportCollapsedDuplicates(_ result: ClaudeDuplicateEmail.DedupeResult) {
        let alert = NSAlert()
        alert.messageText = result.removedCount == 1
            ? "Duplicate Claude account removed"
            : "Duplicate Claude accounts removed"
        let lines = result.collapsedEmails.map { ClaudeDuplicateEmail.userMessage(email: $0) }
        alert.informativeText = lines.joined(separator: "\n")
            + "\n\nKept one connection per email. Sign in again only for a different Claude account."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        // Always icon-only Brim mark — never usage % / tool glyphs in the status item.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusImage(attention: false)
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.title = ""
        statusItem = item

        model.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        settings.$connections.combineLatest(settings.$emptyIsland, settings.$showIsland, settings.$playful)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        // The island's right wing stops at this item, so lay it out again whenever the item moves or resizes.
        if let window = item.button?.window {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                NotificationCenter.default.publisher(for: name, object: window)
                    .sink { [weak self] _ in Task { @MainActor in self?.island?.position() } }
                    .store(in: &cancellables)
            }
        }
    }

    private static func statusImage(attention: Bool) -> NSImage? {
        BrimAssets.statusItemImage(attention: attention)
            ?? NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Brim")
    }

    /// Dot on the mark when something needs the user's attention (not for routine usage %).
    private func statusItemNeedsAttention() -> Bool {
        if settings.enabledConnections.isEmpty { return true }
        for tool in model.featuredTools {
            if tool.statusMessage != nil && !tool.hasData { return true }
            // Critically high plan use — same bar as island attention mood.
            if (tool.tightestWindow?.usedPercent ?? 0) >= 95 { return true }
        }
        return false
    }

    private func updateStatusItem() {
        guard let item = statusItem else { return }
        let attention = statusItemNeedsAttention()
        item.length = NSStatusItem.squareLength
        item.button?.image = Self.statusImage(attention: attention)
        item.button?.title = ""
        item.button?.imagePosition = .imageOnly
        if settings.enabledConnections.isEmpty {
            item.button?.toolTip = "Brim — nothing connected"
        } else {
            item.button?.toolTip = statusItemTooltip()
        }
        item.menu = settings.enabledConnections.isEmpty ? buildEmptyMenu() : buildMenu()
    }

    /// Hover summary when the bar itself is icon-only (or as a fallback tooltip).
    /// Lists every plan window per tool — never only the tightest %.
    private func statusItemTooltip() -> String {
        let tools = model.featuredTools.filter(\.hasData)
        guard !tools.isEmpty else { return "Brim" }
        let parts = tools.prefix(4).map { tool -> String in
            if !tool.planWindows.isEmpty {
                return "\(tool.name): \(Format.allUsed(tool.planWindows, kind: tool.kind))"
            }
            return "\(tool.name) \(Format.tokens(tool.today.total))"
        }
        return parts.joined(separator: " · ")
    }

    private func buildEmptyMenu() -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: "No AI tools connected.", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(menuItem("Add Account…", action: #selector(addAccountFromMenu), symbol: "person.badge.plus"))
        if !settings.connections.isEmpty {
            menu.addItem(menuItem("Connect All", action: #selector(connectAll), symbol: "link"))
        }
        menu.addItem(menuItem("Settings…", action: #selector(openSettings), key: ",", symbol: "gearshape"))
        menu.addItem(menuItem("Check for Updates…", action: #selector(checkForUpdates), symbol: "arrow.triangle.2.circlepath"))
        let show = NSMenuItem(title: "Show Island", action: #selector(showEmptyIsland), keyEquivalent: "")
        show.state = settings.showIsland && settings.emptyIsland == .small ? .on : .off
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Brim", action: #selector(NSApplication.terminate(_:)), key: "q", symbol: "xmark.square", bindTarget: false))
        return menu
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let tools = model.featuredTools
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let title = NSMutableAttributedString(string: "Today  ", attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        title.append(NSAttributedString(string: "\(Format.tokens(model.snapshot.todayTokens)) tokens",
                                        attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .bold)]))
        header.attributedTitle = title
        header.isEnabled = false
        menu.addItem(header)

        for tool in tools {
            var text = "\(tool.name): "
            if tool.hasData {
                var parts: [String] = []
                if tool.hasTokenData { parts.append("\(Format.tokens(tool.today.total)) tokens") }
                parts += tool.planWindows.map { "\($0.label) \(Format.used($0))" }
                text += parts.isEmpty ? "connected" : parts.joined(separator: " · ")
            } else {
                text += tool.statusMessage.map { String($0.prefix(60)) } ?? "connecting…"
            }
            let row = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            row.isEnabled = false
            row.image = BrimAssets.menuImage(for: tool.kind)
            let needsAttention = (tool.tightestWindow?.usedPercent ?? 0) >= 80 || (tool.statusMessage != nil && !tool.hasData)
            if needsAttention {
                row.attributedTitle = NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.systemOrange])
            }
            menu.addItem(row)
        }
        menu.addItem(.separator())

        if island?.state.steppedAside == true || settings.useNotchAnyway {
            if island?.state.steppedAside == true {
                let note = NSMenuItem(title: "Another app is using the notch. Showing here instead.", action: nil, keyEquivalent: "")
                note.isEnabled = false
                menu.addItem(note)
            }
            let anywayTitle = settings.useNotchAnyway ? "Stop Using Notch Anyway" : "Use Notch Anyway"
            let anywaySymbol = settings.useNotchAnyway ? "rectangle.portrait.arrowtriangle.2.outward" : "rectangle.portrait.arrowtriangle.2.inward"
            menu.addItem(menuItem(anywayTitle, action: #selector(toggleUseNotchAnyway), symbol: anywaySymbol))
            menu.addItem(.separator())
        }

        let toggle = NSMenuItem(title: "Show Island", action: #selector(toggleIsland), keyEquivalent: "")
        toggle.state = settings.showIsland ? .on : .off
        toggle.target = self
        menu.addItem(toggle)
        let playful = NSMenuItem(title: "Playful Animations", action: #selector(togglePlayful), keyEquivalent: "")
        playful.state = settings.playful ? .on : .off
        playful.target = self
        menu.addItem(playful)
        menu.addItem(.separator())
        menu.addItem(menuItem("Refresh", action: #selector(refreshNow), key: "r", symbol: "arrow.clockwise"))
        menu.addItem(menuItem("Add Account…", action: #selector(addAccountFromMenu), symbol: "person.badge.plus"))
        menu.addItem(menuItem("Disconnect All", action: #selector(disconnectAll), symbol: "person.crop.circle.badge.minus"))
        menu.addItem(menuItem("Settings…", action: #selector(openSettings), key: ",", symbol: "gearshape"))
        menu.addItem(menuItem("Check for Updates…", action: #selector(checkForUpdates), symbol: "arrow.triangle.2.circlepath"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Brim", action: #selector(NSApplication.terminate(_:)), key: "q", symbol: "xmark.square", bindTarget: false))
        return menu
    }

    /// Action row with a leading SF Symbol, matching the system Settings / Quit icon style.
    /// Quit keeps `bindTarget: false` so `terminate:` walks the responder chain to NSApp.
    private func menuItem(
        _ title: String,
        action: Selector,
        key: String = "",
        symbol: String,
        bindTarget: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if bindTarget { item.target = self }
        // Size the glyph for menu rows; leave system template rendering alone (mutating
        // isTemplate on the shared system image can blank some symbols in the menu bar).
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.copy() as? NSImage {
            image.size = NSSize(width: 16, height: 16)
            item.image = image
        }
        return item
    }

    @objc private func toggleIsland() {
        // Assign through the setter so @Published + UserDefaults didSet always fire (Bool.toggle() can miss).
        settings.showIsland = !settings.showIsland
        updateStatusItem()
    }

    @objc private func toggleUseNotchAnyway() {
        settings.useNotchAnyway = !settings.useNotchAnyway
        island?.checkNotchOccupancy()
        updateStatusItem()
    }

    @objc private func togglePlayful() {
        settings.playful = !settings.playful
        updateStatusItem()
    }

    @objc private func showEmptyIsland() {
        settings.showIsland = true
        settings.emptyIsland = .small
    }

    @objc private func refreshNow() {
        model.refresh(forceAccounts: true)
    }

    @objc private func checkForUpdates() {
        Task { @MainActor in
            await BrimUpdateUI.check(from: nil)
        }
    }

    @objc private func connectAll() {
        model.connectAll()
    }

    @objc private func disconnectAll() {
        model.disconnectAll()
    }

    // MARK: - Settings window

    @objc func openSettings() {
        setup.show(.settings, title: "Brim", size: NSSize(width: 920, height: 640), refresh: true) {
            AppShellView(model: model, settings: settings)
        }
    }

    @objc private func addAccountFromMenu() {
        openAddAccount(AddAccountRequest())
    }

    func openAddAccount(_ request: AddAccountRequest) {
        let title = request.welcome ? "Welcome to Brim" : "Connect"
        setup.show(.addAccount, title: title, size: NSSize(width: 520, height: 640), refresh: true) {
            AddAccountView(model: model, settings: settings, request: request) { [weak self] in self?.setup.close() }
        }
    }

    func openFirstRun() {
        setup.show(.firstRun, title: "Welcome to Brim", size: NSSize(width: 560, height: 640), refresh: true) {
            FirstRunView(model: model, settings: settings) { [weak self] in self?.setup.close() }
        }
    }
}

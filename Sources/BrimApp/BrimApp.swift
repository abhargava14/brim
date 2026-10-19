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
        setUpStatusItem()
        island = IslandController(
            model: model, settings: settings, setup: setup,
            statusItemFrame: { [weak self] in self?.statusItem?.button?.window?.frame },
            openSettings: { [weak self] in self?.openSettings() }
        )
        model.start()

        // First run: show settings so people see which tools were found and how to add more.
        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            openSettings()
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Brim")
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
        statusItem = item

        model.$snapshot.combineLatest(settings.$showInMenuBar, settings.$compactMetric, settings.$placement)
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

    private func updateStatusItem() {
        guard let item = statusItem else { return }
        // One glyph and one value, for the most urgent tool; the menu lists all of them.
        let showValue = settings.showInMenuBar || settings.placement == .menuBarOnly
        let top = model.featuredTools.first(where: \.hasData)
        let symbol = showValue ? top?.kind.symbol ?? "sparkle" : "sparkle"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Brim")
        item.button?.title = showValue ? top.map { " " + model.compactValue(for: $0) } ?? "" : ""
        item.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let tools = model.featuredTools
        let header = NSMenuItem(title: "Today: \(Format.tokens(model.snapshot.todayTokens)) tokens · \(tools.count) connected", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for tool in tools {
            var text = "\(tool.name): "
            if tool.hasData {
                var parts: [String] = []
                if tool.hasTokenData { parts.append("\(Format.tokens(tool.today.total)) tokens") }
                parts += tool.planWindows.map { "\($0.label) \(Format.percent($0.usedPercent))" }
                text += parts.isEmpty ? "connected" : parts.joined(separator: " · ")
            } else {
                text += tool.statusMessage.map { String($0.prefix(60)) } ?? "connecting…"
            }
            let row = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            row.isEnabled = false
            row.image = NSImage(systemSymbolName: tool.kind.symbol, accessibilityDescription: nil)
            menu.addItem(row)
        }
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Show Island", action: #selector(toggleIsland), keyEquivalent: "")
        toggle.state = settings.showIsland ? .on : .off
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        if settings.enabledConnections.isEmpty {
            menu.addItem(withTitle: "Connect All", action: #selector(connectAll), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Disconnect All", action: #selector(disconnectAll), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Connections & Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Brim", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func toggleIsland() {
        settings.showIsland.toggle()
        updateStatusItem()
    }

    @objc private func refreshNow() {
        model.refresh(forceAccounts: true)
    }

    @objc private func connectAll() {
        model.connectAll()
    }

    @objc private func disconnectAll() {
        model.disconnectAll()
    }

    // MARK: - Settings window

    @objc func openSettings() {
        setup.show(.settings, title: "Brim", size: NSSize(width: 600, height: 680)) {
            SettingsView(model: model, settings: settings)
        }
    }
}

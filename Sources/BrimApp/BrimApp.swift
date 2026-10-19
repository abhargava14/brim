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

    private static var defaultImage: NSImage? { NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Brim") }

    private func updateStatusItem() {
        guard let item = statusItem else { return }
        // One glyph and one value, for the most urgent tool; the menu lists all of them.
        let showValue = settings.showInMenuBar || settings.placement == .menuBarOnly
        let top = model.featuredTools.first(where: \.hasData)
        if settings.enabledConnections.isEmpty {
            item.button?.image = NSImage(systemSymbolName: "square.dashed", accessibilityDescription: "Brim: nothing connected")
            item.button?.title = ""
        } else {
            item.button?.image = showValue ? top.flatMap { BrimAssets.menuImage(for: $0.kind, size: 15) } ?? Self.defaultImage : Self.defaultImage
            item.button?.title = showValue ? top.map { " " + model.compactValue(for: $0) } ?? "" : ""
        }
        item.menu = settings.enabledConnections.isEmpty ? buildEmptyMenu() : buildMenu()
    }

    private func buildEmptyMenu() -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: "No AI tools connected.", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Add Connection…", action: #selector(openSettings), keyEquivalent: "").target = self
        if !settings.connections.isEmpty {
            menu.addItem(withTitle: "Connect All", action: #selector(connectAll), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        let show = NSMenuItem(title: "Show Island", action: #selector(showEmptyIsland), keyEquivalent: "")
        show.state = settings.showIsland && settings.emptyIsland == .small ? .on : .off
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Brim", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
                parts += tool.planWindows.map { "\($0.label) \(Format.percent($0.usedPercent))" }
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

        let toggle = NSMenuItem(title: "Show Island", action: #selector(toggleIsland), keyEquivalent: "")
        toggle.state = settings.showIsland ? .on : .off
        toggle.target = self
        menu.addItem(toggle)
        let playful = NSMenuItem(title: "Playful Animations", action: #selector(togglePlayful), keyEquivalent: "")
        playful.state = settings.playful ? .on : .off
        playful.target = self
        menu.addItem(playful)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Add Connection…", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Disconnect All", action: #selector(disconnectAll), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Brim", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func toggleIsland() {
        settings.showIsland.toggle()
        updateStatusItem()
    }

    @objc private func togglePlayful() {
        settings.playful.toggle()
    }

    @objc private func showEmptyIsland() {
        settings.showIsland = true
        settings.emptyIsland = .small
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

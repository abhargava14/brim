import AppKit
import SwiftUI

/// Owns the one setup window. Asking for a different kind replaces what the open window shows,
/// so two setup screens never edit the connections at the same time. The island stays compact
/// while it is open (see `IslandController`).
@MainActor
final class SetupWindows: NSObject, ObservableObject, NSWindowDelegate {
    enum Kind: Equatable {
        case settings
        case addAccount
        case firstRun
    }

    @Published private(set) var open: Kind?
    private var window: NSWindow?
    private var shown: Kind?

    /// `refresh` replaces the content even when the window already shows `kind`.
    func show<Content: View>(_ kind: Kind, title: String, size: NSSize, refresh: Bool = false, @ViewBuilder content: () -> Content) {
        let window = self.window ?? makeWindow()
        if shown != kind || refresh {
            window.contentViewController = NSHostingController(rootView: content())
            window.title = title
            window.setContentSize(size)
            if self.window == nil { window.center() }
            shown = kind
        }
        style(window, for: kind)
        self.window = window
        open = kind
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        open = nil
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    /// Add Connection uses Brim’s dark branded chrome; the main app shell is a calm light window
    /// (Wispr-inspired layout, not a system Preferences sheet). First run stays a system window.
    private func style(_ window: NSWindow, for kind: Kind) {
        switch kind {
        case .addAccount:
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
        case .settings:
            window.appearance = NSAppearance(named: .aqua)
            window.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
        case .firstRun:
            window.appearance = nil
            window.backgroundColor = .windowBackgroundColor
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.styleMask.remove(.fullSizeContentView)
        }
    }
}

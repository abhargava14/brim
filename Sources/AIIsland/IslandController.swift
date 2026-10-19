import AppKit
import Combine
import SwiftUI

/// Geometry and expansion state shared by the island window and its SwiftUI content.
@MainActor
final class IslandState: ObservableObject {
    @Published var isExpanded = false
    @Published var hasNotch = false
    @Published var notchWidth: CGFloat = 0
    /// Height of the menu bar (or the notch) on the island's screen.
    @Published var barHeight: CGFloat = 32
    /// Size of the visible island, measured by the view; used for hover hit-testing.
    @Published var islandSize: CGSize = .zero

    static let expandedWidth: CGFloat = 440
    static let wingWidth: CGFloat = 92
    /// Wings grow to this while an event (connected, near a limit, …) is showing.
    static let eventWingWidth: CGFloat = 140

    var compactWidth: CGFloat { compactWidth(forEvent: false) }

    func compactWidth(forEvent event: Bool) -> CGFloat {
        let wing = event ? Self.eventWingWidth : Self.wingWidth
        return hasNotch ? notchWidth + 2 * wing : (event ? 300 : 230)
    }
}

/// A borderless panel that never takes focus, floats above the menu bar and shows on every Space.
final class IslandPanel: NSPanel {
    convenience init() {
        self.init(
            contentRect: NSRect(origin: .zero, size: IslandController.canvas),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Delivers the first click to buttons even though the panel never becomes key.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Places the island at the top center of the main screen and expands it while the pointer is over it.
///
/// The panel is a fixed, mostly transparent canvas. It ignores the mouse except while the pointer
/// is over the visible island, so the menu bar underneath keeps working.
@MainActor
final class IslandController {
    static let canvas = CGSize(width: 640, height: 680)

    let state = IslandState()
    private let panel = IslandPanel()
    private let settings: AppSettings
    private var monitors: [Any] = []
    private var collapseTask: Task<Void, Never>?
    private var expandTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(model: UsageModel, settings: AppSettings, openSettings: @escaping () -> Void) {
        self.settings = settings
        let root = IslandView(model: model, settings: settings, state: state, openSettings: openSettings)
        panel.contentView = ClickThroughHostingView(rootView: root)

        position()
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.position() } }
            .store(in: &cancellables)

        settings.$showIsland
            .sink { [weak self] show in Task { @MainActor in self?.setVisible(show) } }
            .store(in: &cancellables)

        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            Task { @MainActor in self?.trackMouse() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            Task { @MainActor in self?.trackMouse() }
            return event
        }) {
            monitors.append(local)
        }
    }

    func setVisible(_ visible: Bool) {
        if visible {
            position()
            panel.orderFrontRegardless()
        } else {
            state.isExpanded = false
            panel.orderOut(nil)
        }
    }

    func toggleExpanded() {
        state.isExpanded.toggle()
    }

    /// The screen with the menu bar; on a MacBook that is usually the one with the notch.
    private var screen: NSScreen? {
        NSScreen.screens.first ?? NSScreen.main
    }

    private func position() {
        guard let screen else { return }
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            state.hasNotch = true
            state.notchWidth = frame.width - left.width - right.width
            state.barHeight = screen.safeAreaInsets.top
        } else {
            state.hasNotch = false
            state.notchWidth = 0
            state.barHeight = max(frame.maxY - screen.visibleFrame.maxY, 24)
        }
        let canvas = Self.canvas
        panel.setFrame(
            NSRect(x: frame.midX - canvas.width / 2, y: frame.maxY - canvas.height, width: canvas.width, height: canvas.height),
            display: true
        )
    }

    /// The visible island in screen coordinates.
    private var islandRect: NSRect {
        guard let screen else { return .zero }
        let size = state.islandSize == .zero
            ? CGSize(width: state.compactWidth, height: state.barHeight)
            : state.islandSize
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
    }

    private func trackMouse() {
        guard panel.isVisible else { return }
        let inside = islandRect.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside

        if inside {
            collapseTask?.cancel()
            collapseTask = nil
            if !state.isExpanded, settings.expandOnHover, expandTask == nil {
                expandTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard let self, !Task.isCancelled else { return }
                    self.state.isExpanded = true
                    self.expandTask = nil
                }
            }
        } else {
            expandTask?.cancel()
            expandTask = nil
            if state.isExpanded, collapseTask == nil {
                collapseTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard let self, !Task.isCancelled else { return }
                    self.state.isExpanded = false
                    self.collapseTask = nil
                }
            }
        }
    }
}

import AppKit
import Combine
import IslandCore
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
    /// Room between the notch and the app's own menu bar item; the right wing never grows past it.
    @Published var rightWingLimit: CGFloat = .infinity
    /// A setup window is open: the island stays compact.
    @Published var expansionLocked = false

    static let expandedWidth: CGFloat = 440
    static let wingWidth: CGFloat = 92
    /// Wings grow to this while an event (connected, near a limit, …) is showing.
    static let eventWingWidth: CGFloat = 140
    static let quietEventWingWidth: CGFloat = 112
    /// A right wing narrower than this shows only the glyph.
    static let glyphOnlyWidth: CGFloat = 40

    var compactWidth: CGFloat { compactWidth(for: nil) }

    func leftWingWidth(for event: IslandEvent.Style?) -> CGFloat {
        switch event {
        case .none: return Self.wingWidth
        case .disconnected: return Self.quietEventWingWidth
        default: return Self.eventWingWidth
        }
    }

    func rightWingWidth(for event: IslandEvent.Style?) -> CGFloat {
        max(0, min(leftWingWidth(for: event), rightWingLimit))
    }

    func compactWidth(for event: IslandEvent.Style?) -> CGFloat {
        hasNotch ? leftWingWidth(for: event) + notchWidth + rightWingWidth(for: event) : (event != nil ? 300 : 230)
    }

    /// Shift that keeps the gap between the wings over the notch when the right wing is capped.
    func xOffset(for event: IslandEvent.Style?) -> CGFloat {
        hasNotch ? (rightWingWidth(for: event) - leftWingWidth(for: event)) / 2 : 0
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
        // Allowed over full-screen apps; `IslandController` hides it there when the user wants.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
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
    /// Height of the island when it hangs below the menu bar.
    static let belowMenuBarHeight: CGFloat = 30

    let state = IslandState()
    private let panel = IslandPanel()
    private let model: UsageModel
    private let settings: AppSettings
    /// The app's own menu bar item, in screen coordinates.
    private let statusItemFrame: () -> NSRect?
    private var monitors: [Any] = []
    private var collapseTask: Task<Void, Never>?
    private var expandTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var fullScreenAppActive = false

    init(model: UsageModel, settings: AppSettings, setup: SetupWindows,
         statusItemFrame: @escaping () -> NSRect?, openSettings: @escaping () -> Void) {
        self.model = model
        self.settings = settings
        self.statusItemFrame = statusItemFrame
        let root = IslandView(model: model, settings: settings, state: state, openSettings: openSettings)
        panel.contentView = ClickThroughHostingView(rootView: root)

        position()
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.position() } }
            .store(in: &cancellables)

        settings.$showIsland.combineLatest(settings.$placement, settings.$hideInFullScreen)
            .sink { [weak self] _, _, _ in Task { @MainActor in self?.updateVisibility() } }
            .store(in: &cancellables)

        state.$isExpanded
            .removeDuplicates()
            .sink { [weak model] expanded in Task { @MainActor in model?.setMomentsPaused(expanded, reason: "expanded") } }
            .store(in: &cancellables)

        setup.$open
            .sink { [weak self] open in Task { @MainActor in self?.lockExpansion(open != nil) } }
            .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.publisher(for: name)
                .sink { [weak self] _ in Task { @MainActor in self?.checkFullScreen() } }
                .store(in: &cancellables)
        }
        checkFullScreen()

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

    /// Shown unless the user turned it off, chose the menu bar only, or a full-screen app is in front.
    private var shouldShow: Bool {
        settings.showIsland && settings.placement != .menuBarOnly && !(settings.hideInFullScreen && fullScreenAppActive)
    }

    private func updateVisibility() {
        // Only full screen holds moments; when the user hides the island they simply play out unseen.
        model.setMomentsPaused(settings.showIsland && settings.placement != .menuBarOnly && !shouldShow, reason: "fullScreen")
        if shouldShow {
            position()
            panel.orderFrontRegardless()
        } else {
            state.isExpanded = false
            panel.orderOut(nil)
        }
    }

    func toggleExpanded() {
        guard !state.expansionLocked else { return }
        state.isExpanded.toggle()
    }

    private func lockExpansion(_ locked: Bool) {
        state.expansionLocked = locked
        if locked {
            expandTask?.cancel()
            expandTask = nil
            state.isExpanded = false
        }
    }

    /// The screen with the menu bar; on a MacBook that is usually the one with the notch.
    private var screen: NSScreen? {
        NSScreen.screens.first ?? NSScreen.main
    }

    /// Lays the island out for the current screen, placement and menu bar. Call again when the
    /// app's menu bar item changes size.
    func position() {
        guard let screen else { return }
        let frame = screen.frame
        let menuBarHeight = max(frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top, 24)
        var top = frame.maxY
        if settings.placement == .belowMenuBar {
            state.hasNotch = false
            state.notchWidth = 0
            state.barHeight = Self.belowMenuBarHeight
            state.rightWingLimit = .infinity
            top = frame.maxY - menuBarHeight
        } else if screen.safeAreaInsets.top > 0,
                  let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            state.hasNotch = true
            state.notchWidth = frame.width - left.width - right.width
            state.barHeight = screen.safeAreaInsets.top
            let notchMaxX = frame.maxX - right.width
            if let item = statusItemFrame(), item.width > 0, frame.intersects(item), item.minX > notchMaxX {
                state.rightWingLimit = item.minX - notchMaxX - 6
            } else {
                state.rightWingLimit = .infinity
            }
        } else {
            state.hasNotch = false
            state.notchWidth = 0
            state.barHeight = max(menuBarHeight, 32)
            state.rightWingLimit = .infinity
        }
        let canvas = Self.canvas
        panel.setFrame(
            NSRect(x: frame.midX - canvas.width / 2, y: top - canvas.height, width: canvas.width, height: canvas.height),
            display: true
        )
    }

    /// Whether the frontmost app has a window covering the island's whole screen. Only window
    /// sizes and owners are read, never their contents or titles.
    private func checkFullScreen() {
        var active = false
        if let screen, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           pid != ProcessInfo.processInfo.processIdentifier,
           let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            active = windows.contains { info in
                guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                      (info[kCGWindowLayer as String] as? Int) == 0,
                      let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
                else { return false }
                return rect.size == screen.frame.size && rect.minX == screen.frame.minX
            }
        }
        guard active != fullScreenAppActive else { return }
        fullScreenAppActive = active
        updateVisibility()
    }

    /// Extra room around the island before the pointer counts as gone, so moving inward or
    /// brushing an edge doesn't close it.
    private static let hoverMargin: CGFloat = 6
    private static let expandedHoverMargin: CGFloat = 16
    private static let collapseDelay: UInt64 = 500_000_000

    /// The visible island in screen coordinates. Width comes from the state (it changes before
    /// the view is measured); height from the view once measured.
    private var islandRect: NSRect {
        guard let screen else { return .zero }
        let event = state.isExpanded ? nil : model.event?.style
        let width = state.isExpanded ? IslandState.expandedWidth : state.compactWidth(for: event)
        var height = state.barHeight
        if state.isExpanded {
            height = state.islandSize.height > state.barHeight ? state.islandSize.height : Self.canvas.height
        }
        let size = CGSize(width: width, height: height)
        let top = panel.frame.maxY
        let midX = screen.frame.midX + (state.isExpanded ? 0 : state.xOffset(for: event))
        return NSRect(x: midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }

    private func trackMouse() {
        guard panel.isVisible else { return }
        let rect = islandRect
        let mouse = NSEvent.mouseLocation
        // Clicks land only on the visible shape; everywhere else they reach the menu bar and apps.
        panel.ignoresMouseEvents = !rect.contains(mouse)
        let margin = state.isExpanded ? Self.expandedHoverMargin : Self.hoverMargin
        let inside = rect.insetBy(dx: -margin, dy: -margin).contains(mouse)

        if inside {
            collapseTask?.cancel()
            collapseTask = nil
            if !state.isExpanded, !state.expansionLocked, settings.expandOnHover, expandTask == nil {
                expandTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard let self, !Task.isCancelled else { return }
                    self.expandTask = nil
                    guard !self.state.expansionLocked else { return }
                    self.state.isExpanded = true
                }
            }
        } else {
            expandTask?.cancel()
            expandTask = nil
            if state.isExpanded, collapseTask == nil {
                collapseTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: Self.collapseDelay)
                    guard let self, !Task.isCancelled else { return }
                    self.state.isExpanded = false
                    self.collapseTask = nil
                }
            }
        }
    }
}

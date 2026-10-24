import AppKit
import Combine
import IslandCore
import SwiftUI

/// How much of a wing still fits next to the notch after status icons (and menus) are cleared.
enum WingDensity {
    /// Glyph, number and unit suffix.
    case full
    /// Glyph and number only.
    case iconNumber
    /// Glyph only.
    case iconOnly
}

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
    /// Room left of the notch before menu titles / other items; the left wing never grows past it.
    @Published var leftWingLimit: CGFloat = .infinity
    /// Room right of the notch before status icons; the right wing never grows past it.
    @Published var rightWingLimit: CGFloat = .infinity
    /// A setup window is open: the island stays compact.
    @Published var expansionLocked = false
    /// No connection is on: a small island that offers to connect one.
    @Published var isEmpty = false
    /// Another app is drawing in the notch; the island stepped aside to the menu bar item.
    @Published var steppedAside = false
    /// Opened by a click, the keyboard or typing: stays open until Esc or a click elsewhere.
    @Published var isPinned = false
    /// The closed notch shows music, a timer or a notice: wider wings.
    @Published var wideWings = false
    /// Wings for music, timers and notices (Brim Island design · 421pt with the notch).
    static let wideWingWidth: CGFloat = 118
    /// Width of the screen the island is on, so the open island never runs off it.
    @Published var screenWidth: CGFloat = 1440

    /// Width of the open island (Brim Island design).
    static let openWidth: CGFloat = 880

    /// Idle wing beside the notch (design v2 · 92pt; capped by menu-bar room).
    static let wingWidth: CGFloat = 92
    static let emptyWingWidth: CGFloat = 30
    /// Wings grow to this while an event (connected, near a limit, …) is showing.
    static let eventWingWidth: CGFloat = 140
    static let quietEventWingWidth: CGFloat = 112
    /// Below this, a wing shows only the glyph (avoids truncated "10…" numbers).
    static let glyphOnlyWidth: CGFloat = 40
    /// At or above this, a wing can show glyph + number + suffix.
    static let fullDensityWidth: CGFloat = 64
    /// Narrower than this next to the notch → fall back to below the menu bar.
    static let minimumNotchWing: CGFloat = 24

    /// Connection count used to size the horizontal expanded island (Cards / Strip).
    @Published var expandedToolCount: Int = 0
    /// When true, expanded columns use the narrow Strip layout.
    @Published var expandedLayoutIsStrip: Bool = false

    var compactWidth: CGFloat { compactWidth(for: nil) }
    var expandedWidth: CGFloat {
        min(Self.openWidth, max(600, screenWidth - 24))
    }

    /// Design v2 IslandWide: 560–920pt from connection count and Cards (196) / Strip (108).
    static func wideWidth(count: Int, strip: Bool) -> CGFloat {
        let n = CGFloat(max(count, 1))
        let unit: CGFloat = strip ? 108 : 196
        let gap: CGFloat = strip ? 6 : 8
        let add: CGFloat = strip ? 84 : 96
        return min(920, max(560, 24 + n * unit + max(0, n - 1) * gap + 8 + add))
    }

    func idealWingWidth(for event: IslandEvent.Style?) -> CGFloat {
        switch event {
        case .none: return wideWings ? Self.wideWingWidth : isEmpty ? Self.emptyWingWidth : Self.wingWidth
        case .disconnected: return Self.quietEventWingWidth
        default: return Self.eventWingWidth
        }
    }

    func leftWingWidth(for event: IslandEvent.Style?) -> CGFloat {
        max(0, min(idealWingWidth(for: event), leftWingLimit))
    }

    func rightWingWidth(for event: IslandEvent.Style?) -> CGFloat {
        max(0, min(idealWingWidth(for: event), rightWingLimit))
    }

    func density(for width: CGFloat) -> WingDensity {
        if width >= Self.fullDensityWidth { return .full }
        if width >= Self.glyphOnlyWidth { return .iconNumber }
        return .iconOnly
    }

    func compactWidth(for event: IslandEvent.Style?) -> CGFloat {
        guard !hasNotch else { return leftWingWidth(for: event) + notchWidth + rightWingWidth(for: event) }
        if event != nil { return 300 }
        if wideWings { return 300 }
        return isEmpty ? 88 : 230
    }

    /// Shift that keeps the gap between the wings over the notch when one wing is capped.
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

    /// True while the island is open, so its text fields can take typing without activating Brim.
    var allowsKey = false

    override var canBecomeKey: Bool { allowsKey }
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
    /// Wide enough for design-v2 expanded island (up to 920pt) plus hover slack.
    static let canvas = CGSize(width: 1000, height: 720)
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
    /// Status icons come and go; re-measure clearance a few times a minute.
    private var clearanceTimer: Timer?
    private var hotKey: HotKey?
    /// The drag pasteboard as last seen, so one file drag opens the Shelf only once.
    private var lastDragCount = NSPasteboard(name: .drag).changeCount

    init(hub: BrimHub, setup: SetupWindows,
         statusItemFrame: @escaping () -> NSRect?, openSettings: @escaping (SettingsSection) -> Void,
         addAccount: @escaping (AddAccountRequest) -> Void) {
        self.model = hub.model
        self.settings = hub.settings
        self.statusItemFrame = statusItemFrame
        let model = hub.model, settings = hub.settings
        let root = IslandView(hub: hub, closed: hub.closed, model: model, settings: settings, state: state, openSettings: openSettings, addAccount: addAccount)
        panel.contentView = ClickThroughHostingView(rootView: root)

        position()
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.position() } }
            .store(in: &cancellables)

        clearanceTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkNotchOccupancy()
                self?.position()
            }
        }
        settings.$notchConflict.combineLatest(settings.$useNotchAnyway)
            .sink { [weak self] _, _ in Task { @MainActor in self?.checkNotchOccupancy(); self?.updateVisibility() } }
            .store(in: &cancellables)

        settings.$showIsland.combineLatest(settings.$placement, settings.$hideInFullScreen, settings.$emptyIsland)
            .sink { [weak self] _, _, _, _ in Task { @MainActor in self?.updateVisibility() } }
            .store(in: &cancellables)

        settings.$connections
            .map { !$0.contains(where: \.isEnabled) }
            .removeDuplicates()
            .sink { [weak self] empty in
                Task { @MainActor in
                    self?.state.isEmpty = empty
                    self?.updateVisibility()
                }
            }
            .store(in: &cancellables)

        state.$isExpanded
            .removeDuplicates()
            .sink { [weak model, weak self] expanded in
                Task { @MainActor in
                    model?.setMomentsPaused(expanded, reason: "expanded")
                    model?.setExpandedHistory(expanded)
                    self?.expansionChanged(expanded)
                }
            }
            .store(in: &cancellables)

        settings.$hotkeyEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in Task { @MainActor in self?.setHotKey(enabled) } }
            .store(in: &cancellables)
        settings.$display
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.position() } }
            .store(in: &cancellables)

        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.publisher(for: name, object: panel)
                .sink { [weak self] note in
                    Task { @MainActor in self?.keyChanged(note.name == NSWindow.didBecomeKeyNotification) }
                }
                .store(in: &cancellables)
        }

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
        // A click in another app closes a pinned island.
        if let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            Task { @MainActor in self?.clickedElsewhere() }
        }) {
            monitors.append(clicks)
        }
        // Esc closes the open island while it has the keyboard.
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53, let self, event.window === self.panel, self.state.isExpanded else { return event }
            Task { @MainActor in self.collapse() }
            return nil
        }) {
            monitors.append(keys)
        }

        // `BRIM_SCREENSHOT=1` locks the expanded island open for capture scripts.
        if ProcessInfo.processInfo.environment["BRIM_SCREENSHOT"] == "1" {
            state.isExpanded = true
            state.expansionLocked = true
            let apply: (UsageSnapshot) -> Void = { [weak model] snap in
                for tool in snap.tools where tool.kind == .claude {
                    model?.setClaudeStyle(.full, for: tool.id)
                }
            }
            apply(model.snapshot)
            model.$snapshot
                .sink { apply($0) }
                .store(in: &cancellables)
        }
    }

    /// Shown unless the user turned it off, chose the menu bar only, hid it until something is
    /// connected, a full-screen app is in front, or another app owns the notch.
    private var shouldShow: Bool {
        userWantsIsland && !(settings.hideInFullScreen && fullScreenAppActive) && !state.steppedAside
    }

    private var userWantsIsland: Bool {
        settings.showIsland && settings.placement != .menuBarOnly && !(state.isEmpty && settings.emptyIsland == .hidden)
    }

    private func updateVisibility() {
        // Only full screen holds moments; when the user hides the island they simply play out unseen.
        model.setMomentsPaused(userWantsIsland && !shouldShow, reason: "fullScreen")
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
        if state.isExpanded {
            collapse()
        } else {
            state.isPinned = true
            state.isExpanded = true
        }
    }

    /// Opens from the keyboard and takes typing right away.
    func openFromKeyboard() {
        guard shouldShow, !state.expansionLocked else { return }
        if state.isExpanded {
            collapse()
            return
        }
        position()
        state.isPinned = true
        state.isExpanded = true
        panel.allowsKey = true
        panel.makeKey()
    }

    func collapse() {
        state.isPinned = false
        state.isExpanded = false
    }

    private func expansionChanged(_ expanded: Bool) {
        panel.allowsKey = expanded
        if !expanded {
            state.isPinned = false
            if panel.isKeyWindow {
                panel.resignKey()
                if panel.isKeyWindow { panel.orderOut(nil); panel.orderFrontRegardless() }
            }
        }
    }

    /// Clicking into a text field makes the panel key: keep the island open while typing.
    private func keyChanged(_ isKey: Bool) {
        if isKey {
            if state.isExpanded { state.isPinned = true }
        } else if state.isPinned, !islandRect.contains(NSEvent.mouseLocation) {
            collapse()
        }
    }

    private func clickedElsewhere() {
        guard state.isExpanded, state.isPinned, !islandRect.contains(NSEvent.mouseLocation) else { return }
        collapse()
    }

    private func setHotKey(_ enabled: Bool) {
        hotKey?.unregister()
        hotKey = enabled ? HotKey { [weak self] in self?.openFromKeyboard() } : nil
    }

    private func lockExpansion(_ locked: Bool) {
        state.expansionLocked = locked
        if locked {
            expandTask?.cancel()
            expandTask = nil
            state.isExpanded = false
        }
    }

    /// The built-in display (with the notch) by default; with "All displays", the one under the pointer.
    private var screen: NSScreen? {
        if settings.display == .all {
            let mouse = NSEvent.mouseLocation
            if let under = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) { return under }
        }
        let builtIn = NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        }
        return builtIn ?? NSScreen.screens.first ?? NSScreen.main
    }

    /// Lays the island out for the current screen, placement and menu bar. Call again when the
    /// app's menu bar item changes size or other status icons move.
    func position() {
        guard let screen else { return }
        let frame = screen.frame
        state.screenWidth = frame.width
        let menuBarHeight = max(frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top, 24)
        var top = frame.maxY
        let wantsNotch = settings.placement == .wrapNotch
            || (settings.placement == .belowMenuBar && settings.placementMovedForCrowding)

        if settings.placement == .belowMenuBar && !settings.placementMovedForCrowding {
            state.hasNotch = false
            state.notchWidth = 0
            state.barHeight = Self.belowMenuBarHeight
            state.leftWingLimit = .infinity
            state.rightWingLimit = .infinity
            top = frame.maxY - menuBarHeight
        } else if screen.safeAreaInsets.top > 0,
                  let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let notchMinX = frame.minX + left.width
            let notchMaxX = frame.maxX - right.width
            let clearance = Self.menuBarClearance(
                on: screen, notchMinX: notchMinX, notchMaxX: notchMaxX,
                ownStatusItem: statusItemFrame(), ownPID: ProcessInfo.processInfo.processIdentifier
            )
            // Not enough room for even a glyph on each side → hang below the menu bar instead.
            let tooCrowded = clearance.left < IslandState.minimumNotchWing
                || clearance.right < IslandState.minimumNotchWing
            if wantsNotch && tooCrowded {
                if settings.placement != .belowMenuBar {
                    settings.isApplyingCrowdingMove = true
                    settings.placementMovedForCrowding = true
                    settings.placement = .belowMenuBar
                    settings.isApplyingCrowdingMove = false
                }
                state.hasNotch = false
                state.notchWidth = 0
                state.barHeight = Self.belowMenuBarHeight
                state.leftWingLimit = .infinity
                state.rightWingLimit = .infinity
                top = frame.maxY - menuBarHeight
            } else {
                if settings.placementMovedForCrowding, settings.placement == .belowMenuBar, !tooCrowded {
                    // Room opened up again; only return if we were the ones who moved it.
                    settings.isApplyingCrowdingMove = true
                    settings.placementMovedForCrowding = false
                    settings.placement = .wrapNotch
                    settings.isApplyingCrowdingMove = false
                }
                state.hasNotch = true
                state.notchWidth = frame.width - left.width - right.width
                state.barHeight = screen.safeAreaInsets.top
                state.leftWingLimit = clearance.left
                state.rightWingLimit = clearance.right
            }
        } else {
            state.hasNotch = false
            state.notchWidth = 0
            state.barHeight = max(menuBarHeight, 32)
            state.leftWingLimit = .infinity
            state.rightWingLimit = .infinity
            if settings.placement == .belowMenuBar {
                top = frame.maxY - menuBarHeight
            }
        }
        let canvas = Self.canvas
        panel.setFrame(
            NSRect(x: frame.midX - canvas.width / 2, y: top - canvas.height, width: canvas.width, height: canvas.height),
            display: true
        )
    }

    /// Another process drawing over the notch (for example a Now Playing widget). Bounds only —
    /// Screen Recording is not required. Honours Settings · "When another app uses the notch".
    func checkNotchOccupancy() {
        guard settings.placement == .wrapNotch else {
            if state.steppedAside { state.steppedAside = false }
            return
        }
        guard settings.notchConflict == .moveToMenuBar, !settings.useNotchAnyway else {
            if state.steppedAside { state.steppedAside = false; updateVisibility() }
            return
        }
        guard let screen, screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            if state.steppedAside { state.steppedAside = false }
            return
        }
        let frame = screen.frame
        let notch = CGRect(x: frame.minX + left.width, y: frame.maxY - screen.safeAreaInsets.top,
                           width: frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        let occupied = Self.notchOccupied(byOtherApp: notch, ownPID: ProcessInfo.processInfo.processIdentifier)
        if occupied != state.steppedAside {
            state.steppedAside = occupied
            updateVisibility()
        }
    }

    /// True when another app's on-screen window intersects the notch at status-bar level or above.
    private static func notchOccupied(byOtherApp notch: CGRect, ownPID: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let main = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        let mainMaxY = main?.frame.maxY ?? notch.maxY
        // Convert AppKit notch (bottom-left origin) to CGWindow bounds (top-left of main, Y down).
        let cgNotch = CGRect(x: notch.minX, y: mainMaxY - notch.maxY, width: notch.width, height: notch.height)
            .insetBy(dx: 4, dy: 2)

        for info in windows {
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            guard layer >= statusLevel - 1 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            // Ignore ordinary status items (short, to the side) and huge desktop windows.
            guard rect.height >= 20, rect.height <= 80, rect.width >= 40, rect.width <= 500 else { continue }
            if rect.intersects(cgNotch) { return true }
        }
        return false
    }

    /// Free space on each side of the notch before other menu-bar items.
    ///
    /// Uses `CGWindowListCopyWindowInfo` bounds only (layer + frame). Screen Recording is not
    /// required for that; window names may be blank without it and are ignored.
    private static func menuBarClearance(
        on screen: NSScreen, notchMinX: CGFloat, notchMaxX: CGFloat,
        ownStatusItem: NSRect?, ownPID: pid_t
    ) -> (left: CGFloat, right: CGFloat) {
        var leftLimit = CGFloat.infinity
        var rightLimit = CGFloat.infinity

        if let item = ownStatusItem, item.width > 0, screen.frame.intersects(item) {
            if item.minX >= notchMaxX - 2 {
                rightLimit = min(rightLimit, item.minX - notchMaxX - 6)
            }
            if item.maxX <= notchMinX + 2 {
                leftLimit = min(leftLimit, notchMinX - item.maxX - 6)
            }
        }

        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else {
            return (leftLimit, rightLimit)
        }

        // CGWindowBounds: origin at the top-left of the main display, Y growing downward.
        let main = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main ?? screen
        let frame = screen.frame
        let bandTop = main.frame.maxY - frame.maxY
        let bandBottom = bandTop + max(screen.safeAreaInsets.top, 24) + 4

        for info in windows {
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            guard layer == statusLevel else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            // Status items are short; skip our island panel and ordinary app windows.
            guard rect.height >= 20, rect.height <= 50, rect.width >= 8, rect.width <= 400 else { continue }
            guard rect.maxY > bandTop, rect.minY < bandBottom else { continue }
            guard rect.maxX > frame.minX, rect.minX < frame.maxX else { continue }
            if let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == ownPID, rect.width > 200 {
                continue
            }

            if rect.minX >= notchMaxX - 2 {
                rightLimit = min(rightLimit, rect.minX - notchMaxX - 6)
            }
            if rect.maxX <= notchMinX + 2 {
                leftLimit = min(leftLimit, notchMinX - rect.maxX - 6)
            }
        }

        return (max(0, leftLimit), max(0, rightLimit))
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
        guard screen != nil else { return .zero }
        let event = state.isExpanded || (!settings.interruptLimits && [.warning, .limit].contains(model.event?.style)) ? nil : model.event?.style
        let width: CGFloat
        if state.isExpanded {
            width = state.expandedWidth
        } else {
            width = state.compactWidth(for: event)
        }
        var height = state.barHeight
        if state.isExpanded {
            height = state.islandSize.height > state.barHeight ? state.islandSize.height : Self.canvas.height
        }
        let size = CGSize(width: width, height: height)
        let top = panel.frame.maxY
        let midX = panel.frame.midX + (state.isExpanded ? 0 : state.xOffset(for: event))
        return NSRect(x: midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }

    private func trackMouse() {
        guard panel.isVisible else { return }
        // "All displays": follow the pointer to another screen while the island is closed.
        if settings.display == .all, !state.isExpanded, let screen, abs(screen.frame.midX - panel.frame.midX) > 1 {
            position()
        }
        let rect = islandRect
        let mouse = NSEvent.mouseLocation
        // Clicks land only on the visible shape; everywhere else they reach the menu bar and apps.
        panel.ignoresMouseEvents = !rect.contains(mouse)
        let margin = state.isExpanded ? Self.expandedHoverMargin : Self.hoverMargin
        let inside = rect.insetBy(dx: -margin, dy: -margin).contains(mouse)

        // Dragging files onto the closed notch opens the Shelf to drop them on.
        if inside, !state.isExpanded, !state.expansionLocked, NSEvent.pressedMouseButtons & 1 != 0 {
            let drag = NSPasteboard(name: .drag)
            if drag.changeCount != lastDragCount, drag.types?.contains(.fileURL) == true {
                lastDragCount = drag.changeCount
                settings.selectedTab = .shelf
                state.isPinned = true
                state.isExpanded = true
                return
            }
        }

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
            if state.isExpanded, !state.expansionLocked, !state.isPinned, collapseTask == nil {
                collapseTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: Self.collapseDelay)
                    guard let self, !Task.isCancelled, !self.state.expansionLocked, !self.state.isPinned else { return }
                    self.state.isExpanded = false
                    self.collapseTask = nil
                }
            }
        }
    }
}

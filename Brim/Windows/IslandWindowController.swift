import AppKit
import os
import SwiftUI
import BrimCore
import BrimFeatures

/// Places the island at the top-center of the built-in display and turns the pointer into hover events.
///
/// Who receives the mouse, per state (spike P1):
/// - hidden, slim line: the 240 × 2 pt hover strip only; the panel ignores the mouse;
/// - compact:  the strip grows to cover the pill, so resting on or clicking the pill opens it;
/// - expanded: the panel takes the mouse only over the island's shape (buttons work); around it, clicks go to
///   your app, though the fixed panel is taller than most tabs. Two mouse listeners run only while it's open.
/// Everywhere else, clicks go straight to the app underneath.
///
/// Accidental-open protection (your choice): the island opens only by
/// resting still (¼ s, any movement restarts the wait), pushing up against the edge, or clicking;
/// each can be switched off in Settings. Sliding along the top edge towards a menu never opens it.
final class IslandWindowController {
    private let coordinator: IslandCoordinator
    private let settings: IslandSettings
    private let geometryStore: IslandDisplayGeometryStore
    private let panel: IslandPanel
    private let hostingView: FirstMouseHostingView<IslandRootView>
    private let strip = HoverStripWindow()
    /// The open island's shape on screen, while it's open.
    private var islandRect: NSRect?
    private var moveMonitors: [Any] = []
    private var restTimer: Task<Void, Never>?
    private var hideAfterAnimation: Task<Void, Never>?
    private var pointerInStrip = false
    private var pointerInIsland = false
    private var restAnchor: NSPoint?
    /// A swipe keeps the pointer still on the pill, which the ¼ s rest would take as "open" (your timer
    /// test, 2026-09-30). After a scroll, resting counts again only once the pointer moves.
    private var restHeldBySwipe = false
    private var pushDistance: CGFloat = 0
    private var lastPushAt = Date.distantPast

    /// Rest still this long to open.
    private static let restDelay: Duration = .milliseconds(250)
    /// Moving more than this (points) restarts the rest timer.
    private static let restTolerance: CGFloat = 3
    /// Push up this far against the edge (points of hand movement) to open.
    private static let pushDistanceToOpen: CGFloat = 24

    init(coordinator: IslandCoordinator, settings: IslandSettings, rootView: IslandRootView,
         geometry: IslandDisplayGeometryStore = IslandDisplayGeometryStore()) {
        self.coordinator = coordinator
        self.settings = settings
        self.geometryStore = geometry
        hostingView = FirstMouseHostingView(rootView: rootView)
        hostingView.sizingOptions = []  // the panel's size is fixed; SwiftUI must not resize it
        panel = IslandPanel(contentRect: NSRect(origin: .zero, size: IslandMetrics.panelSize))
        panel.contentView = hostingView

        strip.onEnter = { [weak self] in self?.pointerEnteredStrip() }
        strip.onMove = { [weak self] event in self?.pointerMovedInStrip(event) }
        strip.onExit = { [weak self] in self?.pointerExitedStrip() }
        strip.onClick = { [weak self] point in self?.stripClicked(at: point) }
        strip.onRightClick = { [weak self] event in self?.stripRightClicked(event) }
        panel.acceptsMouseMovedEvents = true  // for the local listener while the pointer is over the open island
    }

    /// A click on a compact notice: x from its left edge, and its width. True when handled (no opening).
    var onCompactClick: ((_ x: CGFloat, _ width: CGFloat) -> Bool)?
    /// A two-finger sideways swipe on the pill or the open island (F9).
    /// Which bubble it began on, or nil for the pill (or the open island).
    var onSwipe: ((BubbleSide?) -> Void)?
    /// The pill's right-click menu, built fresh each time (docs/05-interaction-model.md: shortcuts, never the
    /// only way). The open island has its own SwiftUI menu with the same items.
    var pillMenu: () -> NSMenu? = { nil }
    /// The bubbles beside the resting pill (decision 8): the pill's click-and-hover area grows to cover them.
    var sideBubbles: () -> SideBubbles = { .none }
    /// A click on the right bubble (a countdown): opens its tab.
    var onRightBubbleClick: (() -> Void)?
    /// The left bubble while it holds the second countdown.
    var onLeftCountdownClick: (() -> Void)?
    /// The slim line's marks (keep-awake dot, countdown bar): a click on the bar opens its tab.
    var slimMarks: () -> SideBubbles = { .none }
    /// Timers listed in the Timers tab (0–2 rows; more scroll): it sets that tab's height.
    var timerRows: () -> Int = { 0 }
    /// Today's events in the Calendar tab (up to 3 show): it sets that tab's height.
    var agendaRows: () -> Int = { 0 }
    private var swipeMonitor: Any?
    private var swipeTravel = (dx: 0.0, dy: 0.0)
    private var swipeOn: BubbleSide?

    func show() {
        listenForSwipes()
        listenForMenus()
        reposition()
        strip.orderFrontRegardless()
        // Re-runs whenever the island's surface or the HUD style changes.
        observe { [weak self] in self?.applyCurrentState() }
    }

    /// Called at start and whenever displays change (resolution, arrangement, lid).
    func reposition() {
        guard let screen = ScreenLocator.islandScreen() else { return }
        geometryStore.value = ScreenLocator.geometry(on: screen)
        let geometry = geometryStore.value
        let size = IslandMetrics.panelSize
        let frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: screen.frame.maxY - geometry.islandTopInset - size.height,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: false)
        applyCurrentState()
    }

    /// How far below the screen's top edge the island ends for `surface` (default: what shows now): the
    /// end-of-session box sits under it.
    func islandBottom(for surface: IslandSurface? = nil) -> CGFloat {
        let surface = surface ?? coordinator.surface
        let geometry = geometryStore.value
        let size = IslandMetrics.size(for: surface, appearance: settings.appearance, agendaRows: agendaRows(),
                                      timerRows: timerRows(), geometry: geometry)
        return geometry.islandTopInset + IslandMetrics.topGap(for: surface, appearance: settings.appearance) + size.height
    }

    // MARK: - Following the coordinator

    private func applyCurrentState() {
        let surface = coordinator.surface
        let appearance = settings.appearance
        let geometry = geometryStore.value
        let islandSize = IslandMetrics.size(for: surface, appearance: appearance, agendaRows: agendaRows(),
                                            timerRows: timerRows(), geometry: geometry)
        let topGap = IslandMetrics.topGap(for: surface, appearance: appearance)
        guard let screen = ScreenLocator.islandScreen() else { return }
        hideAfterAnimation?.cancel()
        if !surface.isExpanded, !holds.subtracting([.debug]).isEmpty {
            holds.subtract([.menu, .afterMenu, .drag])  // closed by something else (the full-screen player): nothing to hold
            afterMenu?.cancel()
            openMenus = 0
        }
        switch surface {
        case .hidden:
            panel.ignoresMouseEvents = true
            setIslandTracking(nil)
            strip.place(Self.topStrip(on: screen, topInset: geometry.islandTopInset))
            // Keep the panel up until the collapse animation has played, then take it off screen.
            hideAfterAnimation = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                self?.panel.orderOut(nil)
            }
        case .slim:
            // Visible, but opens like "nothing showing": only by the switches you left on.
            panel.ignoresMouseEvents = true
            setIslandTracking(nil)
            panel.orderFrontRegardless()
            strip.place(Self.topStrip(on: screen, topInset: geometry.islandTopInset))
        case .compact:
            panel.ignoresMouseEvents = true
            setIslandTracking(nil)
            panel.orderFrontRegardless()
            let sides = sideBubbles()
            strip.place(Self.compactArea(on: screen, size: islandSize, topGap: topGap,
                                         ring: IslandMetrics.timerBubble(appearance: appearance, geometry: geometry),
                                         left: sides.hasLeft, right: sides.right != nil,
                                         topInset: geometry.islandTopInset))
        case .expanded:
            panel.orderFrontRegardless()
            strip.place(Self.topStrip(on: screen, topInset: geometry.islandTopInset))
            setIslandTracking(islandSize, topGap: topGap)
        }
    }

    // MARK: - Opening from the top edge

    /// The visible pill always opens on a ¼ s rest or a click (your choice, 2026-09-29).
    /// The three top-edge switches in Settings apply when nothing is showing, or only the slim line.
    private var pillIsShowing: Bool {
        if case .compact = coordinator.surface { return true }
        return false
    }

    /// Your switches apply everywhere, the visible pill included (your fix, 2026-09-30: with "click" only, resting
    /// on the pill still opened it, from the 29 Sep rule that the pill always opens on a rest or a click).
    private var restOpens: Bool { settings.openOnRest }
    private var clickOpens: Bool { settings.openOnClick }

    private func pointerEnteredStrip() {
        pointerInStrip = true
        restHeldBySwipe = false
        restAnchor = NSEvent.mouseLocation
        pushDistance = 0
        startRestTimer()
    }

    private func pointerMovedInStrip(_ event: NSEvent) {
        let location = NSEvent.mouseLocation

        // Push up: the pointer is pinned at the very top, but your hand keeps moving up.
        // (deltaY is negative for upward movement; pushes more than 0.4 s apart don't add up.)
        if settings.openOnPush, event.deltaY < 0,
           let screen = ScreenLocator.islandScreen(),
           location.y >= screen.frame.maxY - geometryStore.value.islandTopInset - 1 {
            if Date.now.timeIntervalSince(lastPushAt) > 0.4 { pushDistance = 0 }
            pushDistance += -event.deltaY
            lastPushAt = .now
            if pushDistance >= Self.pushDistanceToOpen { return open(because: "push") }
        }

        // Rest still: any real movement restarts the wait, so sliding towards a menu never opens it.
        if let anchor = restAnchor, hypot(location.x - anchor.x, location.y - anchor.y) > Self.restTolerance {
            restAnchor = location
            restHeldBySwipe = false
            startRestTimer()
        }
    }

    private func pointerExitedStrip() {
        pointerInStrip = false
        restTimer?.cancel()
        pushDistance = 0
        updateHover()
    }

    private func stripRightClicked(_ event: NSEvent) {
        // Only on something you can see: the pill, a glance, or the slim line.
        guard pillIsShowing || coordinator.surface == .slim, let menu = pillMenu(), let view = strip.contentView else { return }
        Usage.note("menu.pill")
        restTimer?.cancel()
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    /// Which bubble a point in the strip is over, or nil for the pill itself (the strip spans the pill and its bubbles).
    private func bubble(atStripX x: CGFloat) -> BubbleSide? {
        let sides = sideBubbles()
        let geometry = geometryStore.value
        let pill = IslandMetrics.pillSize(appearance: settings.appearance, geometry: geometry)
        let ring = IslandMetrics.timerBubble(appearance: settings.appearance, geometry: geometry)
        let leftReach = sides.hasLeft ? ring.centreOffset + ring.side / 2 : pill.width / 2
        let fromCentre = x - leftReach  // the pill's centre sits `leftReach` in from the strip's left edge
        if sides.right != nil, fromCentre >= pill.width / 2 + 4 { return .right }
        if sides.hasLeft, fromCentre <= -(pill.width / 2 + 4) { return .left }
        return nil
    }

    /// A click on the slim line's countdown bar, or right of it (your check, 2026-10-01: clicking the timer's bar
    /// opened the island on Music).
    private func slimBarClicked(atStripX x: CGFloat) -> Bool {
        guard coordinator.surface == .slim else { return false }
        let marks = slimMarks()
        guard marks.right != nil else { return false }
        let appearance = settings.appearance
        let parts = IslandMetrics.SlimParts(line: coordinator.slimCarriesMusic, dot: marks.left, bar: true)
        let geometry = geometryStore.value
        let barStart = IslandMetrics.slimBarStart(appearance: appearance, parts: parts, geometry: geometry)
        return x - strip.frame.width / 2 >= barStart - IslandMetrics.slimPartWidths(appearance: appearance,
                                                                                     geometry: geometry).gap
    }

    private func stripClicked(at point: NSPoint) {
        // The slim line's countdown bar opens its tab, like the bubble beside the pill.
        if slimBarClicked(atStripX: point.x) {
            restTimer?.cancel()
            onRightBubbleClick?()
            return
        }
        // A countdown bubble opens its tab, even while music plays: the right one, or the left one when it holds a
        // countdown (keep-awake off). Keep-awake's bubble opens the island like the pill does.
        switch bubble(atStripX: point.x) {
        case .right?:
            restTimer?.cancel()
            onRightBubbleClick?()
            return
        case .left? where sideBubbles().leftCountdown != nil:
            restTimer?.cancel()
            onLeftCountdownClick?()
            return
        default:
            break
        }
        // A compact notice may take the click itself (the calendar reminder's Join end, "Time's up").
        if case .compact = coordinator.surface, onCompactClick?(point.x, strip.frame.width) == true { return }
        guard clickOpens else { return }
        open(because: "click")
    }

    private func startRestTimer() {
        restTimer?.cancel()
        // "Time's up" waits for your click (resting on it would hide it behind the open island).
        guard restOpens, !restHeldBySwipe, coordinator.surface != .compact(.timerDone) else { return }
        restTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.restDelay)
            guard !Task.isCancelled, let self, self.pointerInStrip else { return }
            self.open(because: "rest")
        }
    }

    private func open(because reason: String) {
        Usage.note("island.open.\(reason)")
        restTimer?.cancel()
        pushDistance = 0
        Log.island.debug("Opening island: \(reason, privacy: .public)")
        coordinator.hoverChanged(true)
    }

    private func updateHover() {
        if pointerInIsland || !holds.isEmpty {
            coordinator.hoverChanged(true)
        } else if !pointerInStrip {
            coordinator.hoverChanged(false)  // the coordinator keeps it open 0.6 s longer
        }
        // Pointer in the strip but not in the island yet: rest, push, or click decides.
    }

    // MARK: - Holding the open island open (your fix round 2, item 4)

    /// Reasons the open island stays open although the pointer left it (your fix round 2, item 4).
    ///
    /// Measured 2026-09-30: the island's right-click menu blocks Brim while it's up, so the island can't close under an
    /// open menu. What closed it: after one menu, the pointer is away from the island, so the usual 0.6 s close starts;
    /// a right-click within it (to change something else) raced that close, which landed as the next menu opened, and
    /// that menu came up without the lyrics items.
    private enum Hold: Hashable {
        /// From a right-click on the open island until its menu closes (also the coffee's lengths menu).
        case menu
        /// 1.5 s after that menu closes, to come back and change something else before the usual close starts.
        case afterMenu
        /// A drag you started inside it (the progress bar, a slider) is still going.
        case drag
        /// A popover from the open island is up (the Timers tab's Today details): it sits below the island, so moving
        /// the pointer onto it used to close the island, and the popover with it (your report, 2026-11-16).
        case popover
        /// Debug screenshots of the real island (`--hold-island`).
        case debug
    }

    private var holds: Set<Hold> = [] {
        didSet { if holds != oldValue { Log.island.debug("Island holds: \(String(describing: self.holds), privacy: .public)") } }
    }
    /// Menus can nest (a submenu); the hold ends when the last one closes.
    private var openMenus = 0
    /// The open island's popovers that are up.
    private var openPopovers: Set<ObjectIdentifier> = []
    private var menuObservers: [NSObjectProtocol] = []
    private var afterMenu: Task<Void, Never>?
    private static let afterMenuWait: Duration = .seconds(1.5)

    #if DEBUG
    /// The menu check's "before" run (A/B): no menu holds at all.
    private var menuHoldsOff: Bool { CommandLine.arguments.contains("--no-menu-hold") }
    #else
    private var menuHoldsOff: Bool { false }
    #endif

    private func listenForMenus() {
        guard menuObservers.isEmpty else { return }
        let center = NotificationCenter.default
        // Handled at once (no queue): Brim's main queue doesn't run while a menu is up, so a queued handler would only
        // run after the menu closed.
        menuObservers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] _ in
            Self.onMain { self?.menuBegan() }
        })
        menuObservers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { [weak self] _ in
            Self.onMain { self?.menuEnded() }
        })
        // SwiftUI's popovers are NSPopovers on the Mac.
        menuObservers.append(center.addObserver(forName: NSPopover.willShowNotification, object: nil, queue: nil) { [weak self] note in
            guard let popover = note.object as? NSPopover else { return }
            let id = ObjectIdentifier(popover)
            Self.onMain { self?.popoverShown(id) }
        })
        menuObservers.append(center.addObserver(forName: NSPopover.didCloseNotification, object: nil, queue: nil) { [weak self] note in
            guard let popover = note.object as? NSPopover else { return }
            let id = ObjectIdentifier(popover)
            Self.onMain { self?.popoverClosed(id) }
        })
    }

    /// A popover opening while the island is open and the pointer in it came from the island (a click on it): the
    /// island stays open until the popover closes (a click elsewhere, or Esc). The full-screen player's popovers
    /// open with the island closed, so they don't count.
    private func popoverShown(_ id: ObjectIdentifier) {
        guard coordinator.surface.isExpanded, pointerInIsland || !holds.isEmpty else { return }
        openPopovers.insert(id)
        holds.insert(.popover)
        updateHover()
    }

    private func popoverClosed(_ id: ObjectIdentifier) {
        guard openPopovers.remove(id) != nil, openPopovers.isEmpty else { return }
        holds.remove(.popover)
        refreshPointer()
    }

    /// Menus post on the main thread; this keeps it safe if one ever doesn't.
    private nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated(work) } else { DispatchQueue.main.async(execute: work) }
    }

    /// A right-click on the open island: hold it open now, before its menu is built, so a close already under way can't
    /// land as the menu opens. If no menu follows, let go.
    private func menuRequested() {
        guard coordinator.surface.isExpanded, !menuHoldsOff else { return }
        afterMenu?.cancel()
        holds.remove(.afterMenu)
        holds.insert(.menu)
        updateHover()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.openMenus == 0, self.holds.contains(.menu) else { return }
            self.holds.remove(.menu)
            self.refreshPointer()
        }
    }

    private func menuBegan() {
        // Only the open island's own menus; Settings' pop-ups don't count.
        guard coordinator.surface.isExpanded || holds.contains(.menu), !menuHoldsOff else { return }
        openMenus += 1
        afterMenu?.cancel()
        holds.remove(.afterMenu)
        holds.insert(.menu)
        updateHover()
    }

    private func menuEnded() {
        guard openMenus > 0 else { return }
        openMenus -= 1
        guard openMenus == 0 else { return }
        holds.remove(.menu)
        holds.insert(.afterMenu)
        afterMenu = Task { [weak self] in
            try? await Task.sleep(for: Self.afterMenuWait)
            guard !Task.isCancelled, let self else { return }
            self.holds.remove(.afterMenu)
            self.refreshPointer()
        }
        refreshPointer()
    }

    /// After a hold ends: where is the pointer now? Closes the island (after the usual 0.6 s) if it's outside.
    private func refreshPointer() {
        guard let rect = islandRect else { return }
        pointerInIsland = rect.contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !pointerInIsland
        updateHover()
    }

    #if DEBUG
    /// Debug: what a pointer move does (re-reads where the pointer is), for the menu check.
    func debugPointerCheck() { refreshPointer() }

    /// Debug: the island's window, for sending it a right-click without moving your pointer.
    var debugPanel: NSPanel { panel }

    /// Debug: keeps the island open for `seconds` wherever the pointer is, for screenshots of the real island.
    func debugHold(for seconds: Double) {
        holds.insert(.debug)
        coordinator.hoverChanged(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.holds.remove(.debug)
            self?.refreshPointer()
        }
    }
    #endif

    /// Tracks the pointer over the expanded island, including the gap above it up to the screen edge.
    /// While the island is open, the pointer's position decides both "still hovering" and whether the panel takes
    /// clicks: over the island's shape it does; anywhere else your app gets them. Nothing runs while it's closed.
    private func setIslandTracking(_ islandSize: CGSize?, topGap: CGFloat = 0) {
        guard let islandSize, let screen = ScreenLocator.islandScreen() else {
            islandRect = nil
            moveMonitors.forEach(NSEvent.removeMonitor)
            moveMonitors = []
            pointerInIsland = false
            return
        }
        let height = topGap + islandSize.height
        islandRect = NSRect(x: screen.frame.midX - islandSize.width / 2,
                            y: screen.frame.maxY - geometryStore.value.islandTopInset - height,
                            width: islandSize.width, height: height)
        if moveMonitors.isEmpty {
            let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
            // Moves over other apps (the panel lets the mouse through there)…
            if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMoved() }
            }) { moveMonitors.append(global) }
            // …and over the island itself, plus the press and release that start and end a drag inside it, and the
            // right-click that opens its menu.
            if let local = NSEvent.addLocalMonitorForEvents(matching: moves.union([.leftMouseDown, .leftMouseUp, .rightMouseDown]),
                                                            handler: { [weak self] event in
                MainActor.assumeIsolated { self?.localMouse(event) }
                return event
            }) { moveMonitors.append(local) }
        }
        pointerMoved()  // where the pointer is right now
    }

    private func localMouse(_ event: NSEvent) {
        switch event.type {
        case .rightMouseDown where event.window === panel:
            menuRequested()
        case .leftMouseDown where event.window === panel && event.modifierFlags.contains(.control):
            menuRequested()  // Control-click, the Mac's other right-click
        case .leftMouseDown where event.window === panel:
            holds.insert(.drag)
        case .leftMouseUp where holds.contains(.drag):
            holds.remove(.drag)
            refreshPointer()
            return
        default:
            break
        }
        pointerMoved()
    }

    private func pointerMoved() {
        guard let rect = islandRect else { return }
        let inside = rect.contains(NSEvent.mouseLocation)
        // A drag that left the island keeps the panel's mouse until you let go.
        panel.ignoresMouseEvents = !inside && !holds.contains(.drag)
        guard inside != pointerInIsland else { return }
        pointerInIsland = inside
        updateHover()
    }

    // MARK: - Geometry (screen coordinates: origin bottom-left)

    private static func topStrip(on screen: NSScreen, topInset: CGFloat) -> NSRect {
        let size = IslandMetrics.hoverStrip
        return NSRect(x: screen.frame.midX - size.width / 2,
                      y: screen.frame.maxY - topInset - size.height,
                      width: size.width, height: size.height)
    }

    /// The pill's area, widened to cover the bubbles beside it.
    private static func compactArea(on screen: NSScreen, size: CGSize, topGap: CGFloat,
                                    ring: (side: CGFloat, centreOffset: CGFloat, top: CGFloat), left: Bool, right: Bool,
                                    topInset: CGFloat) -> NSRect {
        let height = max(topGap + size.height, (left || right) ? ring.top + ring.side : 0)
        let leftReach = left ? ring.centreOffset + ring.side / 2 : size.width / 2
        let rightReach = right ? ring.centreOffset + ring.side / 2 : size.width / 2
        return NSRect(x: screen.frame.midX - leftReach, y: screen.frame.maxY - topInset - height,
                      width: leftReach + rightReach, height: height)
    }

    // MARK: - Swipes

    /// Two-finger swipes over the pill or the open island (F9). A local listener: these are Brim's own
    /// windows, which system-wide listeners never hear (found 2026-09-30).
    private func listenForSwipes() {
        guard swipeMonitor == nil else { return }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.scrolled(event) }
            return event
        }
    }

    private func scrolled(_ event: NSEvent) {
        // Whole gestures on the island only; the glide after lifting the fingers doesn't count.
        guard event.window === panel || event.window === strip else { return }
        if event.window === strip {
            restTimer?.cancel()
            restHeldBySwipe = true
        }
        guard event.momentumPhase.isEmpty else { return }
        if event.phase == .began {
            swipeTravel = (0, 0)
            // Where your fingers were when the swipe began: a bubble (only it hides) or the pill (your fix round 2).
            swipeOn = event.window === strip ? bubble(atStripX: event.locationInWindow.x) : nil
        }
        swipeTravel.dx += Double(event.scrollingDeltaX)
        swipeTravel.dy += Double(event.scrollingDeltaY)
        guard event.phase == .ended else { return }
        if SwipeRules.isSideways(dx: swipeTravel.dx, dy: swipeTravel.dy) { onSwipe?(swipeOn) }
        swipeTravel = (0, 0)
    }
}

enum ScreenLocator {
    /// The MacBook's built-in display; without one (a Mac mini, Studio or Pro, or a lid closed on an external display),
    /// the primary display, the one with the menu bar in Displays settings. Not `NSScreen.main`: that follows keyboard
    /// focus, so on two monitors it moved as you clicked windows, and the island sat on one screen while its hover strip
    /// watched the other (code review, 2026-11-17).
    static func islandScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        } ?? NSScreen.screens.first
    }

    /// Converts AppKit's display facts into the layout profile shared by the window and SwiftUI.
    /// The gap between the auxiliary top areas is the system-reported camera-housing width; it avoids a model list
    /// and stays correct when resolution or display scaling changes.
    static func geometry(on screen: NSScreen) -> IslandDisplayGeometry {
        let left = screen.auxiliaryTopLeftArea
        let right = screen.auxiliaryTopRightArea
        let gap = if let left, let right { right.minX - left.maxX } else { CGFloat.zero }
        let notchWidth = gap > 0 && screen.safeAreaInsets.top > 0 ? gap : nil
        return IslandDisplayGeometry(screenSize: screen.frame.size,
                                     notchWidth: notchWidth,
                                     topSafeInset: screen.safeAreaInsets.top,
                                     backingScale: screen.backingScaleFactor)
    }
}

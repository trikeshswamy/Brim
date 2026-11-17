import AppKit
import SwiftUI
import BrimCore
import BrimFeatures

/// The first-launch welcome's window (your pick A, 2026-10-25): in the island's place at the top centre of the
/// island's screen, while the island itself stays hidden. Like the island's panel it never activates Brim and takes
/// the first click; unlike it, it doesn't follow the pointer: it stays until you finish or skip.
@MainActor
final class WelcomeController {
    private let flow: WelcomeFlow
    private let island: IslandCoordinator
    private let panel = WelcomePanel()
    private var pointing: Task<Void, Never>?

    /// Fixed, so the card's height can spring between steps without resizing the window (that stutters, see
    /// IslandMetrics.panelSize). The tallest step plus Glass's 6 pt gap and Black's two 6 pt shoulders.
    private static let size = CGSize(width: WelcomeView.width + 12, height: WelcomeView.windowHeight)

    init(flow: WelcomeFlow, island: IslandCoordinator, settings: IslandSettings, nowPlaying: NowPlayingStore) {
        self.flow = flow
        self.island = island
        let hosting = WelcomeHostingView(rootView: WelcomeView(flow: flow, settings: settings, nowPlaying: nowPlaying,
                                                               pointer: Self.pointerFromFace))
        panel.contentView = hosting
        flow.onShowingChange = { [weak self] showing in showing ? self?.show() : self?.hide() }
    }

    /// Where the pointer is, measured from Brim's eyes at the top centre of the island's screen (x right, y down).
    static func pointerFromFace() -> CGPoint? {
        guard let screen = ScreenLocator.islandScreen() else { return nil }
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - screen.frame.midX, y: (screen.frame.maxY - 18) - mouse.y)
    }

    /// Displays changed: the island's screen may have too.
    func reposition() {
        guard panel.isVisible else { return }
        place()
    }

    private func show() {
        island.setWelcomeOpen(true)
        place()
        panel.alphaValue = 1
        panel.orderFrontRegardless()  // the card grows out of the pill's shape itself (WelcomeView)
        Usage.note("welcome.show")
        watchForPointing()
    }

    /// Hello asks you to point at the top of your screen: when the pointer reaches the top edge above the card, it
    /// moves on by itself. Ten checks a second, only while Hello shows.
    private func watchForPointing() {
        pointing?.cancel()
        pointing = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, self.flow.isShowing {
                if self.flow.step == .hello, self.flow.outcome == nil, self.pointerIsAtTheTop() {
                    await self.flow.pointedAtTop()
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func pointerIsAtTheTop() -> Bool {
        guard let screen = ScreenLocator.islandScreen() else { return false }
        let mouse = NSEvent.mouseLocation
        return mouse.y >= screen.frame.maxY - 4 && abs(mouse.x - screen.frame.midX) <= WelcomeView.width / 2
    }

    /// The card shrinks back into the pill first (about 0.4 s), then the island takes its place again, so the welcome
    /// leaves the way it came.
    private func hide() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(420))
            guard let self, !self.flow.isShowing else { return }  // shown again meanwhile
            self.pointing?.cancel()
            self.panel.orderOut(nil)
            self.island.setWelcomeOpen(false)
        }
    }

    /// Centred at the top of the island's screen; the card hangs from the edge (Black) or floats under it (Glass).
    private func place() {
        guard let screen = ScreenLocator.islandScreen() else { return }
        let size = Self.size
        panel.setFrame(NSRect(x: (screen.frame.midX - size.width / 2).rounded(), y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }
}

/// Every Space and over full-screen apps, above the menu bar like the island; it never activates Brim or takes the
/// keyboard (macOS's own permission prompts do that).
private final class WelcomePanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false  // the island's shape draws its own edge
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        allowsToolTipsWhenApplicationIsInactive = true  // the details live in the buttons' hover text
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click: Brim is never the active app.
private final class WelcomeHostingView: NSHostingView<WelcomeView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

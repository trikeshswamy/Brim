import AppKit
import SwiftUI
import BrimCore
import BrimFeatures

/// The full-screen player's window (PRD F6): covers the MacBook's screen, above the menu bar and the Dock,
/// fades in and out, and closes with Esc or the close button. The island stays hidden while it's open.
/// A plain covering window, not a macOS full-screen Space, so it opens instantly without a Space animation.
final class FullScreenPlayerController {
    private let coordinator: IslandCoordinator
    private let makeContent: (FullScreenActions) -> FullScreenPlayerView
    private let playPause: () -> Void
    private let next: () -> Void
    private let back: () -> Void
    private var window: FullScreenWindow?

    /// `playPause`: the space bar, as in Apple Music's full-screen player (your video, 2026-10-07). `next` and `back`:
    /// ⌘→ and ⌘← (your ask, 2026-10-29).
    init(coordinator: IslandCoordinator, playPause: @escaping () -> Void, next: @escaping () -> Void,
         back: @escaping () -> Void, content: @escaping (FullScreenActions) -> FullScreenPlayerView) {
        self.coordinator = coordinator
        self.playPause = playPause
        self.next = next
        self.back = back
        makeContent = content
    }

    var isOpen: Bool { window != nil }
    /// Esc goes here first: true when it was used (the lyrics timing bar closes), so the player stays open.
    var escapeFirst: (() -> Bool)?

    func open() {
        guard window == nil, let screen = ScreenLocator.islandScreen() else { return }
        Usage.note("fullScreen.open")
        let window = FullScreenWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)  // above the menu bar
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: makeContent(FullScreenActions(close: { [weak self] in self?.close() })))
        window.onEscape = { [weak self] in
            if self?.escapeFirst?() == true { return }
            self?.close()
        }
        window.onSpace = { [weak self] in self?.playPause() }
        window.onNext = { [weak self] in self?.next() }
        window.onBack = { [weak self] in self?.back() }
        window.setFrame(screen.frame, display: false)
        window.alphaValue = 0
        self.window = window

        coordinator.setFullScreenPlayerOpen(true)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            window.animator().alphaValue = 1
        }
    }

    func close() {
        guard let window else { return }
        self.window = nil
        coordinator.setFullScreenPlayerOpen(false)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { window.orderOut(nil) }
        })
    }
}

/// A borderless window that can take the keyboard: Esc closes it, the space bar plays and pauses, ⌘→ goes to the
/// next song, ⌘← to the start of this one (again: the one before).
final class FullScreenWindow: NSWindow {
    var onEscape: (() -> Void)?
    var onSpace: (() -> Void)?
    var onNext: (() -> Void)?
    var onBack: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// The space bar alone (no ⌘, ⌥, ⌃ or ⇧, not held down), before any button inside can take it.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 49, !event.isARepeat,
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, let onSpace {
            onSpace()
            return
        }
        // ⌘ and an arrow alone (arrows also carry the function-key flag), one step per press, not while held.
        if event.type == .keyDown, !event.isARepeat, event.keyCode == 124 || event.keyCode == 123,
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command {
            (event.keyCode == 124 ? onNext : onBack)?()
            return
        }
        super.sendEvent(event)
    }
}

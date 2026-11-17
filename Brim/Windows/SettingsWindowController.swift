import AppKit
import SwiftUI

/// Settings in a plain AppKit window (architecture D10).
/// While it's open Brim becomes a regular app (Dock icon + menu bar): macOS reliably brings
/// windows of regular apps to the front, and ⌘W / ⌘Q / ⌘, work. Closing it makes Brim invisible again.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let makeContent: () -> NSViewController
    private var window: NSWindow?

    init<Content: View>(content: @escaping () -> Content) {
        makeContent = { NSHostingController(rootView: content()) }
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // Brim's own icon, from its own bundle, for the Dock and ⌘Tab (your report, 2026-11-17: ⌘Tab showed macOS's
        // blank placeholder). macOS looks an icon up by the app's ID, and with several copies of Brim registered (old
        // builds, a download next to the installed one) it can land on one it can't draw.
        // From the asset catalog: every size up to 1024 px. The built .icns holds only up to 256 px (0.39.4).
        if let icon = NSImage(named: "AppIcon")
            ?? Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:)) {
            NSApp.applicationIconImage = icon
        }
        NSApp.setActivationPolicy(.regular)
        // Next turn of the run loop, so the Dock icon exists before we ask to come forward.
        DispatchQueue.main.async {
            // Centred on your screen every time, not where it was last or near the island (your 3.6), and only once
            // its size is known (see `makeWindow`).
            window.layoutIfNeeded()
            window.center()
            // Forced, not polite: `activate()` lets macOS refuse while another app is in front (⌥⌘, from anywhere),
            // and Settings then opened without the keyboard, so ⌘W went to that other app (your ask, 2026-11-17).
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private func makeWindow() -> NSWindow {
        let content = makeContent()
        let window = NSWindow(contentViewController: content)
        window.title = "Brim Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.delegate = self
        // A new window doesn't know SwiftUI's size yet (it starts near 0 × 0): centring it then put its corner in the
        // middle of the screen, and the 720 × 520 page grew up and to the right, off screen (your screenshot,
        // 2026-10-07: the first open only). So it takes the page's size first.
        content.view.layoutSubtreeIfNeeded()
        window.setContentSize(content.view.fittingSize)
        return window
    }

    /// The window's frame and its screen's, for the debug check (`--settings-check`).
    var frames: (window: NSRect, screen: NSRect)? {
        guard let window, let screen = window.screen ?? NSScreen.main else { return nil }
        return (window.frame, screen.visibleFrame)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

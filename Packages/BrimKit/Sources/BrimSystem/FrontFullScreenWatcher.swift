import AppKit
import ApplicationServices
import BrimCore

/// Whether the front app's window is in macOS full screen (your report, 2026-10-02: the pill drew the eye over
/// full-screen content). Read through Accessibility (the window's `AXFullScreen`, checked on your Mac: Dia in full
/// screen said yes), only when the front app or the Space changes, and once more 0.75 s later when the full-screen
/// animation has settled. Never on a timer.
@MainActor
public final class FrontFullScreenWatcher {
    /// Called on the main thread, only when the answer changes.
    public var onChange: ((Bool) -> Void)?
    private var current = false
    private var observers: [NSObjectProtocol] = []
    private var settle: DispatchWorkItem?

    public init() {}

    public func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            })
        }
        check()
    }

    private func check() {
        read()
        settle?.cancel()
        let again = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.read() } }
        settle = again
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: again)
    }

    /// Asks off the main thread (an app that doesn't answer can take up to 0.5 s), answers on it.
    private func read() {
        guard AXIsProcessTrusted(), let front = NSWorkspace.shared.frontmostApplication else { return update(false) }
        let pid = front.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let full = Self.isFullScreen(pid: pid)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update(full) } }
        }
    }

    private func update(_ full: Bool) {
        guard full != current else { return }
        current = full
        Log.island.notice("Front window full screen: \(full, privacy: .public)")
        onChange?(full)
    }

    nonisolated private static func isFullScreen(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var window: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return false }
        var full: AnyObject?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, "AXFullScreen" as CFString, &full) == .success else { return false }
        return (full as? Bool) ?? false
    }
}

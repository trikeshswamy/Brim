import AppKit

/// Tells Brim when the Mac wakes and when displays change. Both are push notifications: no polling.
public final class SystemEventsObserver {
    public var onWake: () -> Void = {}
    public var onScreensChanged: () -> Void = {}
    private var tokens: [NSObjectProtocol] = []

    public init() {}

    public func start() {
        guard tokens.isEmpty else { return }
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // queue: .main guarantees the main thread; tell the compiler so.
            MainActor.assumeIsolated { self?.onWake() }
        })
        tokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onScreensChanged() }
        })
    }
}

import AppKit
import ApplicationServices
import BrimCore

/// Takes over the volume, mute, and brightness keys with an active event tap.
///
/// - Needs Privacy & Security → Device Control and Data Access ("Accessibility" before macOS 27).
/// - Asks macOS only for system-defined events (media keys), so ordinary typing never reaches Brim.
/// - If Brim quits, the tap disappears and the keys go straight back to macOS. If macOS disables
///   the tap, Brim removes it and makes one delayed recovery attempt outside the callback.
/// - Permission changes are deliberately handled after a Brim restart, not from macOS's privacy notification.
public final class MediaKeyTap: MediaKeyService {
    public private(set) var access: KeyAccess = .off {
        didSet { if access != oldValue { onAccessChange?(access) } }
    }
    public private(set) var permissionGranted = false
    public var onAccessChange: ((KeyAccess) -> Void)?

    private var handler: ((MediaKeyPress) -> Bool)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var recoveryTask: Task<Void, Never>?

    public init() {}

    /// Refreshes only the read-only macOS trust bit. It never prompts and never changes the event tap.
    public func refreshPermissionStatus() {
        permissionGranted = AXIsProcessTrusted()
    }

    public func start(handler: @escaping (MediaKeyPress) -> Bool) {
        self.handler = handler
        refreshPermissionStatus()
        installIfPermitted()
    }

    public func stop() {
        recoveryTask?.cancel()
        recoveryTask = nil
        removeTap()
        handler = nil
        access = .off
    }

    private func installIfPermitted() {
        guard handler != nil, tap == nil else { return }
        guard AXIsProcessTrusted() else {
            access = .needsPermission
            return
        }
        let mask = CGEventMask(1 << 14)  // NX_SYSDEFINED: media keys only
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: mask, callback: mediaKeyCallback, userInfo: context) else {
            Log.app.error("Key tap: macOS refused to create it")
            access = .failed("macOS refused the key tap. Try switching Brim off and on in Privacy & Security.")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        runLoopSource = source
        access = .active
        Log.app.notice("Key tap: active (volume, mute, brightness)")
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    /// Called for every event the tap sees, on the main thread. `true` = swallow it.
    fileprivate func shouldSwallow(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.app.notice("Key tap: macOS paused it (\(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public)); scheduling one recovery")
            // Never re-enable from inside this callback. Permission changes can arrive at the same
            // time as a disabled tap; doing it synchronously can make macOS's privacy UI hang.
            recoveryTask = Task { @MainActor [weak self] in
                self?.recoverFromDisable()
            }
            return false
        }
        guard type.rawValue == 14, let handler, let event = NSEvent(cgEvent: event), event.subtype.rawValue == 8,
              let press = MediaKeyPress.decode(data1: event.data1,
                                               optionShift: event.modifierFlags.contains([.option, .shift]),
                                               control: event.modifierFlags.contains(.control))
        else { return false }
        return handler(press)
    }

    @MainActor
    private func recoverFromDisable() {
        guard recoveryTask != nil else { return }
        removeTap()
        access = .failed("macOS paused Brim's key tap. Brim will try once to restore it.")
        recoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.handler != nil else { return }
            self.recoveryTask = nil
            self.installIfPermitted()
            if self.access != .active {
                self.access = .failed("macOS paused Brim's key tap. Restart Brim to try again.")
            }
        }
    }
}

/// The C callback macOS calls. The tap's run-loop source is on the main run loop, so this runs on the main thread.
private let mediaKeyCallback: CGEventTapCallBack = { _, type, event, context in
    guard let context else { return Unmanaged.passUnretained(event) }
    let keys = Unmanaged<MediaKeyTap>.fromOpaque(context).takeUnretainedValue()
    // Safe: macOS calls this synchronously on the main thread, and nothing else touches the event meanwhile.
    nonisolated(unsafe) let mainThreadEvent = event
    let swallow = MainActor.assumeIsolated { keys.shouldSwallow(type: type, event: mainThreadEvent) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

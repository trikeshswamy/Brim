import AppKit
import Carbon.HIToolbox
import os
import BrimCore
import BrimSystem

/// ⌥⌘, opens Brim's Settings from any app (your ask, 2026-11-17; Settings → Keyboard turns it off).
///
/// A Carbon hot key: macOS hands Brim just this one combination, wherever you are, with no permission to ask (unlike
/// the volume keys, which need Accessibility). If another app registered ⌥⌘, first, macOS refuses it and Settings says
/// so. ⌘, alone is left to each app: it's their own Settings (inside Brim's windows, Brim's menu answers it).
@MainActor
final class SettingsHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    /// Whether it's wanted (Settings → Keyboard), so a layout change can register it again.
    private var wanted = false
    private var layoutObserver: NSObjectProtocol?

    init(action: @escaping () -> Void) {
        self.action = action
        // Switching keyboard layouts (Dvorak, AZERTY…) moves the key that types ",": register it again on the new one.
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: KeyboardLayout.changedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.wanted else { return }
                self.unregister()
                self.setEnabled(true)
            }
        }
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    /// On or off; true when it's in the state asked (false: on was asked, and another app has ⌥⌘,).
    @discardableResult
    func setEnabled(_ on: Bool) -> Bool {
        wanted = on
        guard on else {
            unregister()
            return true
        }
        guard hotKey == nil else { return true }
        listen()
        var registered: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4252_4D53), id: 1)  // 'BRMS'
        // The key that types "," on your layout, not QWERTY's comma key (your report, 2026-11-17: Dvorak).
        let key = KeyboardLayout.keyCode(typing: ",") ?? UInt16(kVK_ANSI_Comma)
        let status = RegisterEventHotKey(UInt32(key), UInt32(cmdKey | optionKey), id,
                                         GetApplicationEventTarget(), 0, &registered)
        guard status == noErr, let registered else {
            Log.app.notice("⌥⌘, for Settings: macOS refused it (\(status, privacy: .public)): another app has it")
            return false
        }
        hotKey = registered
        return true
    }

    private func listen() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let me = Unmanaged<SettingsHotKey>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in me.action() }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}

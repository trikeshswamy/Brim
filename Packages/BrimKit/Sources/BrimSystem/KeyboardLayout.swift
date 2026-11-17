import Carbon.HIToolbox
import Foundation

/// Which physical key types a character on a keyboard layout (your report, 2026-11-17: on Dvorak, the key that types
/// "," is the one QWERTY calls W, so ⌥⌘, registered by QWERTY's position opened nothing for you).
///
/// Keys are read with ⌘ held, as a shortcut is pressed: layouts like "Dvorak – QWERTY ⌘" switch to QWERTY then, and
/// this finds the key you'd really press. Nil when the layout has no such key.
public enum KeyboardLayout {
    /// The key typing `character` on the layout in use now.
    public static func keyCode(typing character: Character) -> UInt16? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return keyCode(typing: character, in: source)
    }

    /// The same for a given layout (tests use Dvorak and U.S.).
    public static func keyCode(typing character: Character, in source: TISInputSource) -> UInt16? {
        guard let target = character.utf16.first, character.utf16.count == 1,
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> UInt16? in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            let command = UInt32((cmdKey >> 8) & 0xFF)
            func types(_ code: UInt16) -> Bool {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), command, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
                return status == noErr && length == 1 && chars[0] == target
            }
            // The usual place first (most layouts), then every other key.
            if character == ",", types(UInt16(kVK_ANSI_Comma)) { return UInt16(kVK_ANSI_Comma) }
            return (0..<128).map(UInt16.init).first(where: types)
        }
    }

    /// A layout by its ID ("com.apple.keylayout.Dvorak"), if it's installed (all of Apple's are).
    public static func source(id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.first
    }

    /// Posted by macOS when you switch keyboard layouts.
    public static let changedNotification = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
}

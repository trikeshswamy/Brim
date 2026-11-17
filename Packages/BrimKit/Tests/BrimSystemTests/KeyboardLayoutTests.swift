import Carbon.HIToolbox
import Testing
@testable import BrimSystem

/// Your report, 2026-11-17: on Dvorak, ⌥⌘, did nothing, because Brim registered QWERTY's comma key.
struct KeyboardLayoutTests {
    @Test func commaIsWherePeopleTypeIt() throws {
        let us = try #require(KeyboardLayout.source(id: "com.apple.keylayout.US"))
        #expect(KeyboardLayout.keyCode(typing: ",", in: us) == UInt16(kVK_ANSI_Comma))
        let dvorak = try #require(KeyboardLayout.source(id: "com.apple.keylayout.Dvorak"))
        #expect(KeyboardLayout.keyCode(typing: ",", in: dvorak) == UInt16(kVK_ANSI_W))  // Dvorak's comma: QWERTY's W
    }

    @Test func dvorakWithQWERTYCommandKeepsQWERTYsComma() throws {
        // "Dvorak – QWERTY ⌘": with ⌘ held it's QWERTY, so the shortcut stays on QWERTY's comma key.
        let mixed = try #require(KeyboardLayout.source(id: "com.apple.keylayout.DVORAK-QWERTYCMD"))
        #expect(KeyboardLayout.keyCode(typing: ",", in: mixed) == UInt16(kVK_ANSI_Comma))
    }
}

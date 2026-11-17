import Testing
@testable import BrimCore

struct MediaKeyTests {
    /// Builds `data1` the way macOS does: code << 16 | state << 8 | repeat.
    private func data1(code: Int, down: Bool, repeating: Bool = false) -> Int {
        code << 16 | (down ? 0xA : 0xB) << 8 | (repeating ? 1 : 0)
    }

    @Test func decodesVolumeAndBrightnessKeys() {
        #expect(MediaKeyPress.decode(data1: data1(code: 0, down: true), optionShift: false)
                == MediaKeyPress(key: .volumeUp, isDown: true))
        #expect(MediaKeyPress.decode(data1: data1(code: 1, down: false), optionShift: false)
                == MediaKeyPress(key: .volumeDown, isDown: false))
        #expect(MediaKeyPress.decode(data1: data1(code: 7, down: true), optionShift: false)?.key == .mute)
        #expect(MediaKeyPress.decode(data1: data1(code: 2, down: true, repeating: true), optionShift: true)
                == MediaKeyPress(key: .brightnessUp, isDown: true, isRepeat: true, fine: true))
        #expect(MediaKeyPress.decode(data1: data1(code: 3, down: true), optionShift: false)?.key == .brightnessDown)
    }

    @Test func leavesOtherKeysToMacOS() {
        #expect(MediaKeyPress.decode(data1: data1(code: 16, down: true), optionShift: false) == nil)  // play/pause
        #expect(MediaKeyPress.decode(data1: data1(code: 21, down: true), optionShift: false) == nil)  // keyboard light
    }

    @Test func stepsFivePercentOrTwoWithOptionShift() {
        #expect(LevelStep.next(from: 0.4375, up: true, fine: false) == 0.45)   // in-between snaps up to the grid
        #expect(LevelStep.next(from: 0.4375, up: false, fine: false) == 0.40)
        #expect(LevelStep.next(from: 0.45, up: true, fine: false) == 0.50)     // on the grid: one full step
        #expect(LevelStep.next(from: 0.45, up: false, fine: false) == 0.40)
        #expect(LevelStep.next(from: 0.4375, up: true, fine: true) == 0.44)    // ⌥⇧: 2%
        #expect(LevelStep.next(from: 0.44, up: true, fine: true) == 0.46)
        #expect(LevelStep.next(from: 0.44, up: false, fine: true) == 0.42)
        #expect(LevelStep.next(from: 0.98, up: true, fine: false) == 1)        // never past 100%
        #expect(LevelStep.next(from: 0.01, up: false, fine: false) == 0)       // never below 0%
        #expect(LevelStep.next(from: 1, up: true, fine: true) == 1)
    }

    @Test func levelsStoredAsFloat32StillMoveAFullStep() {
        // CoreAudio returned 0.79999995 for 80% on your Mac (self-test run 2): a press must still move 2% / 5%.
        let eighty = 0.79999995231628418
        #expect(LevelStep.next(from: eighty, up: true, fine: true) == 0.82)
        #expect(LevelStep.next(from: eighty, up: false, fine: true) == 0.78)
        #expect(LevelStep.next(from: eighty, up: true, fine: false) == 0.85)
        #expect(LevelStep.next(from: eighty, up: false, fine: false) == 0.75)
        #expect(LevelStep.next(from: 0.80000001192, up: true, fine: true) == 0.82)  // … and just above
        #expect(LevelStep.next(from: 0.80000001192, up: false, fine: true) == 0.78)
    }
}

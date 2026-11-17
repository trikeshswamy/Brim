/// A volume, mute, or brightness key press, decoded from macOS's media-key event
/// (a "system-defined" event, NX_SYSDEFINED, subtype 8). Brim never sees ordinary typing.
public struct MediaKeyPress: Equatable, Sendable {
    public enum Key: Equatable, Sendable {
        case volumeUp, volumeDown, mute, brightnessUp, brightnessDown
    }

    public var key: Key
    public var isDown: Bool
    /// Held down: macOS sends repeats about 12 times a second.
    public var isRepeat: Bool
    /// Option-Shift held: quarter steps (64 per range), like macOS.
    public var fine: Bool
    /// Control held: the volume keys change only the music app (your pick, 2026-11-17).
    public var control: Bool

    public init(key: Key, isDown: Bool, isRepeat: Bool = false, fine: Bool = false, control: Bool = false) {
        self.key = key
        self.isDown = isDown
        self.isRepeat = isRepeat
        self.fine = fine
        self.control = control
    }

    /// `data1` of the event: key code in bits 16–31; state (0xA down, 0xB up) in bits 8–15; repeat in bit 0.
    /// Returns nil for keys Brim leaves to macOS (play/pause, next, keyboard backlight…).
    public static func decode(data1: Int, optionShift: Bool, control: Bool = false) -> MediaKeyPress? {
        let code = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0xFFFF
        let key: Key
        switch code {
        case 0: key = .volumeUp        // NX_KEYTYPE_SOUND_UP
        case 1: key = .volumeDown      // NX_KEYTYPE_SOUND_DOWN
        case 2: key = .brightnessUp    // NX_KEYTYPE_BRIGHTNESS_UP
        case 3: key = .brightnessDown  // NX_KEYTYPE_BRIGHTNESS_DOWN
        case 7: key = .mute            // NX_KEYTYPE_MUTE
        default: return nil
        }
        return MediaKeyPress(key: key, isDown: (flags & 0xFF00) >> 8 == 0xA, isRepeat: flags & 0x1 == 1, fine: optionShift,
                             control: control)
    }
}

/// Brim's volume and brightness steps (your choice, 2026-09-29): 5% per press, 2% with Option-Shift.
/// A press moves to the next multiple of the step in its direction, so an in-between level
/// (set by a slider or another app) snaps onto the grid. Worked out in whole percents to avoid rounding drift.
public enum LevelStep {
    public static let normalPercent = 5
    public static let finePercent = 2

    public static func next(from level: Double, up: Bool, fine: Bool) -> Double {
        let step = fine ? finePercent : normalPercent
        let position = level * 100 / Double(step)
        // CoreAudio and DisplayServices keep levels as 32-bit floats: 80% can read back as 79.999995%.
        // Within 0.01% of a step counts as on it, so every press moves a full step (found by the self-test).
        let tolerance = 0.01 / Double(step)
        let steps = up ? Int((position + tolerance).rounded(.down)) + 1 : Int((position - tolerance).rounded(.up)) - 1
        return Double(min(max(steps * step, 0), 100)) / 100
    }
}

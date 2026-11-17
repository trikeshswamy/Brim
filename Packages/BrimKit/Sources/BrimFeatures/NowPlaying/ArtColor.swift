import AppKit
import BrimCore

/// The album art's colour for the waveform and the slim line, adjusted to stay readable.
enum ArtColor {
    /// White (or black in Light Mode) when the art is black-and-white or missing.
    static func resolve(_ tint: TintColor?, onDark: Bool) -> NSColor {
        guard let tint else { return onDark ? .white : .black }
        let readable = tint.readable(onDark: onDark)
        return NSColor(hue: readable.hue, saturation: readable.saturation, brightness: readable.brightness, alpha: 1)
    }
}

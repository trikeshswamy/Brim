import CoreGraphics
import Foundation
import BrimCore

/// The built-in display's brightness through DisplayServices, the private framework behind macOS's own
/// brightness controls. Loaded at runtime (dlopen), so a macOS without it just means `level()` returns nil
/// and Brim hands the brightness keys back to macOS. Read access was verified on 26A428 (feasibility §F4).
public final class DisplayBrightnessService: BrightnessService {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let get: GetBrightness?
    private let set: SetBrightness?

    public init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        get = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetBrightness.self) }
        set = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetBrightness.self) }
        if get == nil || set == nil { Log.app.error("DisplayServices brightness functions are missing") }
    }

    public func level() -> Double? {
        guard let get, let display = Self.builtInDisplay() else { return nil }
        var value = Float(0)
        return get(display, &value) == 0 ? Double(value) : nil
    }

    @discardableResult
    public func setLevel(_ level: Double) -> Bool {
        guard let set, let display = Self.builtInDisplay() else { return false }
        return set(display, Float(min(max(level, 0), 1))) == 0
    }

    /// The MacBook's own screen, if it's on (not with the lid closed).
    ///
    /// Searches the online list, not the active one: while the screen is mirrored (AirPlay, a projector), macOS
    /// lists only the main mirror as active, and the built-in screen would go missing. Found 2026-11-12 with
    /// AirPlay mirroring on: Brim handed every brightness key back to macOS, so Apple's display showed.
    private static func builtInDisplay() -> CGDirectDisplayID? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count = UInt32(0)
        guard CGGetOnlineDisplayList(16, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsAsleep($0) == 0 }
    }
}

/// The built-in display's brightness as the HUD shows it.
public struct BrightnessState: Equatable, Sendable {
    /// 0 … 1
    public var level: Double

    public init(level: Double) {
        self.level = level
    }

    /// Apple's sun symbols: small sun below half, big sun from half (PRD §7.3).
    public var symbolName: String {
        level < 0.5 ? "sun.min.fill" : "sun.max.fill"
    }
}

/// Reads and sets the built-in display's brightness (0 … 1).
/// The live version uses DisplayServices, a private framework, so it sits behind this protocol;
/// if it ever disappears, `level()` returns nil and Brim hands the brightness keys back to macOS.
@MainActor
public protocol BrightnessService: AnyObject {
    /// nil when there's no built-in display (lid closed) or the private API is missing.
    func level() -> Double?
    @discardableResult func setLevel(_ level: Double) -> Bool
}

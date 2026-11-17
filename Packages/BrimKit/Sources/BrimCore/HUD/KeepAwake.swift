import Foundation

/// Keep-awake (F11, your pick 2026-09-30): the Mac doesn't sleep, nor its display, until you turn it off.
/// Live: a macOS power assertion (public, no permission; macOS releases it if Brim quits). Tests: a fake.
@MainActor
public protocol KeepAwakeService: AnyObject {
    /// True when macOS accepted it.
    @discardableResult
    func setAwake(_ on: Bool) -> Bool
}

/// How long keep-awake lasts, and its words (your fix round, 2026-09-30). Pure, so tested.
public enum KeepAwakeRules {
    /// The menu, in order: 10 min, 30 min, 1 hour, 2 hours, then until you stop it (nil). No custom length: you
    /// picked 1 and 2 hours over one.
    public static let choices: [Int?] = [10, 30, 60, 120, nil]

    /// "10 min", "30 min", "1 hour", "2 hours", "Until I stop it" (your words).
    public static func label(minutes: Int?) -> String {
        guard let minutes else { return "Until I stop it" }
        guard minutes >= 60, minutes % 60 == 0 else { return "\(minutes) min" }
        return minutes == 60 ? "1 hour" : "\(minutes / 60) hours"
    }

    /// The bubble's ring: the share still to go, 1 just after you start and 0 as it ends.
    public static func share(since start: Date, until end: Date, at now: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(max(end.timeIntervalSince(now) / total, 0), 1)
    }
}

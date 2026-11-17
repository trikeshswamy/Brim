import Foundation

public enum TimeFormat {
    /// 127 → "2:07", 3725 → "1:02:05". Negative values show as 0.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Remaining time with a minus sign: "−1:41". Rounded up, so elapsed + remaining always equals the duration.
    public static func remaining(_ seconds: TimeInterval) -> String {
        "\u{2212}" + clock(seconds.rounded(.up))
    }
}

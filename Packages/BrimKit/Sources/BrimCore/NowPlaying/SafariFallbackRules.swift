import Foundation

/// When the Safari fallback looks at Safari (2026-10-26). A full look at one large page took 3–7 s of work every
/// second while nothing played, so it now looks only when there's a reason: a WebKit process (Safari's pages) is
/// playing sound, or did within the last minute (so a video you paused still shows, and the island's paused-pill
/// rules can run). With Safari closed or silent, no looking at all.
public enum SafariFallbackRules {
    /// After the sound stops: keep looking this long (the kept pill hides after a minute paused anyway).
    public static let afterSound: TimeInterval = 60

    public static func shouldLook(safariRunning: Bool, webAudioPlaying: Bool, lastHeard: Date?, now: Date) -> Bool {
        guard safariRunning else { return false }
        if webAudioPlaying { return true }
        guard let lastHeard else { return false }
        return now.timeIntervalSince(lastHeard) < afterSound
    }

    /// How long to wait before the next check: every second while sound plays (positions stay current), every two
    /// otherwise (the check itself is then just two cheap questions to macOS).
    public static func interval(webAudioPlaying: Bool) -> TimeInterval { webAudioPlaying ? 1 : 2 }
}

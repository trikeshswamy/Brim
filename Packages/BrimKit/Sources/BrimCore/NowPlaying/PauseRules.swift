import Foundation

/// A pause report can carry a position a moment old: your video (2026-10-07) showed the full-screen lyrics step back one
/// line the instant you paused, then return about a second later, when a fresh report came. So when the same song goes
/// from playing to paused and the report is behind where the song had got to by less than `tolerance`, Brim keeps where
/// it had got to. A bigger difference is a real jump (you seeked), and changes while playing pass as they come.
public enum PauseRules {
    public static let tolerance: TimeInterval = 3

    public static func settled(_ next: NowPlaying, after previous: NowPlaying?, at now: Date) -> NowPlaying {
        guard let previous, previous.isPlaying, !next.isPlaying, previous.identity == next.identity,
              let reached = previous.position(at: now), let reported = next.position(at: now),
              reported < reached, reached - reported < tolerance else { return next }
        var kept = next
        kept.elapsed = reached
        kept.timestamp = now
        return kept
    }
}

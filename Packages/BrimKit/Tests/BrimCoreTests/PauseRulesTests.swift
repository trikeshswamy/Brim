import Foundation
import Testing
@testable import BrimCore

/// Your "Lyrics Toggle and Jump" video (2026-10-07): pausing stepped the lyrics back a line for a second.
struct PauseRulesTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func song(playing: Bool, elapsed: TimeInterval, at date: Date, title: String = "Unknown / Nth") -> NowPlaying {
        NowPlaying(title: title, artist: "Hozier", isPlaying: playing, duration: 300, elapsed: elapsed, timestamp: date,
                   playbackRate: playing ? 1 : 0)
    }

    @Test func aPauseReportThatsAMomentOldKeepsWhereTheSongWas() {
        let playing = song(playing: true, elapsed: 100, at: t0)
        let now = t0.addingTimeInterval(5)   // the song had reached 105
        let stale = song(playing: false, elapsed: 104.1, at: now)
        #expect(PauseRules.settled(stale, after: playing, at: now).position(at: now) == 105)
    }

    @Test func realChangesPassAsTheyCome() {
        let playing = song(playing: true, elapsed: 100, at: t0)
        let now = t0.addingTimeInterval(5)
        let sought = song(playing: false, elapsed: 60, at: now)                    // you jumped back, then paused
        #expect(PauseRules.settled(sought, after: playing, at: now) == sought)
        let ahead = song(playing: false, elapsed: 105.4, at: now)                  // a report ahead of Brim's guess
        #expect(PauseRules.settled(ahead, after: playing, at: now) == ahead)
        let other = song(playing: false, elapsed: 104, at: now, title: "Another song")
        #expect(PauseRules.settled(other, after: playing, at: now) == other)       // another song
        let stillPlaying = song(playing: true, elapsed: 104, at: now)
        #expect(PauseRules.settled(stillPlaying, after: playing, at: now) == stillPlaying)
        let paused = song(playing: false, elapsed: 104, at: now)
        #expect(PauseRules.settled(paused, after: paused, at: now) == paused)      // already paused
    }
}

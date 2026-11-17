import Foundation
import Testing
@testable import BrimCore

struct NowPlayingTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func positionAdvancesWhilePlaying() {
        let item = NowPlaying(title: "S", isPlaying: true, duration: 100, elapsed: 10, timestamp: start)
        #expect(item.position(at: start.addingTimeInterval(5)) == 15)
    }

    @Test func positionIsFrozenWhilePaused() {
        let item = NowPlaying(title: "S", isPlaying: false, duration: 100, elapsed: 10, timestamp: start, playbackRate: 1)
        #expect(item.position(at: start.addingTimeInterval(5)) == 10)
    }

    @Test func positionRespectsPlaybackRate() {
        let item = NowPlaying(title: "S", isPlaying: true, duration: 100, elapsed: 10, timestamp: start, playbackRate: 2)
        #expect(item.position(at: start.addingTimeInterval(5)) == 20)
    }

    @Test func positionStopsAtDuration() {
        let item = NowPlaying(title: "S", isPlaying: true, duration: 100, elapsed: 98, timestamp: start)
        #expect(item.position(at: start.addingTimeInterval(60)) == 100)
    }

    @Test func skipButtonsForVideosPodcastsAndLongItems() {
        #expect(NowPlaying(title: "S", duration: 200).prefersSkipButtons == false)
        #expect(NowPlaying(title: "S", duration: 200, mediaType: "kMRMediaRemoteNowPlayingInfoTypeVideo").prefersSkipButtons)
        #expect(NowPlaying(title: "S", bundleIdentifier: "com.apple.podcasts", duration: 200).prefersSkipButtons)
        #expect(NowPlaying(title: "S", duration: 3600).prefersSkipButtons)
    }

    /// Your screenshot (2026-10-01): a 14:20 YouTube video in Dia, reported with no kind and no album, got previous /
    /// next. In a browser, no album now means a video; a music site names the album and keeps previous / next.
    @Test func browserVideosGetSkipButtons() {
        #expect(NowPlaying(title: "V", artist: "Channel", bundleIdentifier: "company.thebrowser.dia", duration: 860)
            .prefersSkipButtons)
        #expect(NowPlaying(title: "V", bundleIdentifier: "com.apple.WebKit.GPU", parentBundleIdentifier: "com.apple.Safari",
                           duration: 300).prefersSkipButtons)
        #expect(NowPlaying(title: "V", album: " ", bundleIdentifier: "com.google.Chrome.beta", duration: 300).prefersSkipButtons)
        #expect(NowPlaying(title: "S", artist: "A", album: "Album", bundleIdentifier: "company.thebrowser.dia", duration: 200)
            .prefersSkipButtons == false)
        // Apps are unchanged: Spotify with no album still has previous / next.
        #expect(NowPlaying(title: "S", bundleIdentifier: "com.spotify.client", duration: 200,
                           mediaType: "kMRMediaRemoteNowPlayingInfoTypeAudio").prefersSkipButtons == false)
    }

    @Test func identityIgnoresPlaybackState() {
        let a = NowPlaying(title: "S", artist: "A", isPlaying: true)
        let b = NowPlaying(title: "S", artist: "A", isPlaying: false, elapsed: 42)
        #expect(a.identity == b.identity)
    }
}

struct TimeFormatTests {
    @Test func clock() {
        #expect(TimeFormat.clock(0) == "0:00")
        #expect(TimeFormat.clock(127.9) == "2:07")
        #expect(TimeFormat.clock(3725) == "1:02:05")
        #expect(TimeFormat.clock(-5) == "0:00")
    }

    @Test func remainingRoundsUpSoTheSumMatchesDuration() {
        // 186 s song at 2.5 s: shows 0:02 elapsed and −3:04 remaining (2 + 184 = 186).
        #expect(TimeFormat.clock(2.5) == "0:02")
        #expect(TimeFormat.remaining(183.5) == "\u{2212}3:04")
    }
}

struct MediaCommandTests {
    @Test func rawValuesMatchTheHelper() {
        // The helper's `send` accepts MediaRemote's MRCommand numbers.
        #expect(MediaCommand.togglePlayPause.rawValue == 2)
        #expect(MediaCommand.nextTrack.rawValue == 4)
        #expect(MediaCommand.previousTrack.rawValue == 5)
        #expect(MediaCommand.skipForward15.rawValue == 13)
    }
}

/// 0.18.1: scrolling through the full-screen lyrics.
struct LyricsBrowseTests {
    @Test func theListStopsAtTheFirstAndLastLines() {
        // A list whose last line starts 900 pt down, anchored 150 pt from the top of the column.
        #expect(LyricsBrowse.clamped(-200, anchor: 150, lastTop: 900) == -200)    // in between: where you scrolled
        #expect(LyricsBrowse.clamped(400, anchor: 150, lastTop: 900) == 150)      // first line at the anchor, no lower
        #expect(LyricsBrowse.clamped(-2000, anchor: 150, lastTop: 900) == -750)   // last line at the anchor, no higher
    }

    @Test func aMouseWheelMovesInNotches() {
        #expect(LyricsBrowse.points(-37, precise: true) == -37)                  // trackpad: points
        #expect(LyricsBrowse.points(-2, precise: false) == -2 * LyricsBrowse.notch)
        #expect(LyricsBrowse.returnAfter == 3)
    }
}

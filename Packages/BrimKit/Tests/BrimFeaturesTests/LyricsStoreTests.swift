import Foundation
import SwiftUI
import Testing
@testable import BrimCore
@testable import BrimFeatures

/// Stands in for LRCLIB: returns a canned answer, counts requests, and records your fixes.
actor FakeLyricsService: LyricsService {
    private(set) var requests: [LyricsQuery] = []
    private let answer: LyricsResult
    private var offsets: [LyricsQuery: TimeInterval] = [:]
    private(set) var savedOffsets: [TimeInterval] = []
    private(set) var versionRequests = 0
    private(set) var used: [Int] = []
    private let versionsAnswer: LyricsVersionsResult

    init(answer: LyricsResult, offset: TimeInterval = 0, versions: LyricsVersionsResult = .failed("none")) {
        self.answer = answer
        self.versionsAnswer = versions
        self.initialOffset = offset
    }
    private let initialOffset: TimeInterval

    func lyrics(for query: LyricsQuery) async -> LyricsResult {
        requests.append(query)
        return answer
    }

    func offset(for query: LyricsQuery) async -> TimeInterval { offsets[query] ?? initialOffset }

    func setOffset(_ offset: TimeInterval, for query: LyricsQuery) async {
        offsets[query] = offset
        savedOffsets.append(offset)
    }

    func versions(for query: LyricsQuery) async -> LyricsVersionsResult {
        versionRequests += 1
        return versionsAnswer
    }

    func use(_ version: LyricsVersion, for query: LyricsQuery) async {
        used.append(version.id)
        offsets[query] = 0
    }
}

struct LyricsStoreTests {
    private let lines = Lyrics.synced([LyricLine(time: 5, text: "a"), LyricLine(time: 10, text: "b")])

    private func song(_ title: String = "Song", elapsed: TimeInterval = 0, playing: Bool = true,
                      duration: TimeInterval = 200) -> NowPlaying {
        NowPlaying(title: title, artist: "Artist", isPlaying: playing, duration: duration, elapsed: elapsed, timestamp: .now)
    }

    private func makeStore(answer: LyricsResult, grace: Duration = .seconds(3)) -> (LyricsStore, FakeLyricsService) {
        let fake = FakeLyricsService(answer: answer)
        let nowPlaying = NowPlayingStore(service: FakeNowPlayingService(), island: IslandCoordinator())
        return (LyricsStore(service: fake, nowPlaying: nowPlaying, dropoutGrace: grace), fake)
    }

    /// Lets the lookup task finish.
    private func settle(_ store: LyricsStore) async {
        for _ in 0..<50 where store.status == .loading { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func looksUpOncePerSong() async {
        let (store, fake) = makeStore(answer: .found(lines))
        store.follow(song(elapsed: 1))
        store.follow(song(elapsed: 2))       // the same song updating (position, play state)
        store.follow(song(elapsed: 3, playing: false))
        await settle(store)
        #expect(store.status == .ready)
        #expect(await fake.requests.count == 1)
    }

    @Test func aNewSongClearsTheOldLyricsImmediately() async {
        let (store, _) = makeStore(answer: .found(lines))
        store.follow(song("One"))
        await settle(store)
        store.follow(song("Two"))
        #expect(store.lyrics == nil)          // no stale lines from the previous song
        #expect(store.status == .loading)
    }

    @Test func podcastsAreNotLookedUp() async {
        let (store, fake) = makeStore(answer: .found(lines))
        store.follow(song(duration: 3600))
        await settle(store)
        #expect(store.status == .none)
        #expect(await fake.requests.isEmpty)
    }

    @Test func offlineIsNotRetriedOnEveryUpdate() async {
        let (store, fake) = makeStore(answer: .offline)
        store.follow(song(elapsed: 1))
        await settle(store)
        store.follow(song(elapsed: 5))
        #expect(store.status == .offline)
        #expect(await fake.requests.count == 1)
    }

    @Test func currentLineIsTrackedOnlyWhileShown() async {
        let (store, _) = makeStore(answer: .found(lines))
        store.follow(song(elapsed: 7))
        await settle(store)
        #expect(store.currentIndex == nil)    // nobody is looking: no work done
        store.beginDisplay()
        store.follow(song(elapsed: 7))
        #expect(store.currentIndex == 0)      // 7 s: first line (5 s) is playing
        store.follow(song(elapsed: 12))       // a seek
        #expect(store.currentIndex == 1)
        store.endDisplay()
    }

    // MARK: Timing fixes (right-click menu)

    private func makeStore(_ fake: FakeLyricsService) -> LyricsStore {
        let nowPlaying = NowPlayingStore(service: FakeNowPlayingService(), island: IslandCoordinator())
        return LyricsStore(service: fake, nowPlaying: nowPlaying)
    }

    /// Lets queued saves reach the fake.
    private func flush() async {
        for _ in 0..<5 { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func times(_ lyrics: Lyrics?) -> [TimeInterval] {
        guard case .synced(let lines)? = lyrics else { return [] }
        return lines.map(\.time)
    }

    @Test func nudgeMovesEveryLineAndIsSaved() async {
        let fake = FakeLyricsService(answer: .found(lines))
        let store = makeStore(fake)
        store.follow(song())
        await settle(store)
        store.nudge(by: -0.25)
        store.nudge(by: -0.25)
        #expect(store.timingOffset == -0.5)
        #expect(times(store.lyrics) == [4.5, 9.5])
        await flush()
        #expect(await fake.savedOffsets == [-0.25, -0.5])  // in order, never reversed
        store.resetTiming()
        #expect(times(store.lyrics) == [5, 10])
    }

    /// Your pick, 2026-11-16: in "Fix Lyrics Timing…", clicking the line being sung lines everything up at once.
    @Test func clickingTheLineBeingSungLinesEverythingUp() async {
        let fake = FakeLyricsService(answer: .found(lines))
        let store = makeStore(fake)
        store.follow(song(elapsed: 7.2, playing: false))  // the singer starts line "b" (shown at 10 s) at 7.2 s; held still
        await settle(store)
        store.syncLine(shownAt: 10)            // outside the bar: nothing happens
        #expect(store.timingOffset == 0)
        store.startSync(in: .island)
        store.syncLine(shownAt: 10)
        // b now starts at 7.0 (7.2 less the 0.2 s it takes to click), and every line moved with it.
        #expect(abs(store.timingOffset - -3.0) < 0.02)
        #expect(times(store.lyrics).map { ($0 * 10).rounded() / 10 } == [2.0, 7.0])
        store.nudge(by: 0.25)                  // the bar's + still fine-tunes
        #expect(abs(store.timingOffset - -2.75) < 0.02)
        store.endSync(in: .fullScreen)         // not its bar: stays
        #expect(store.syncing == .island)
        store.follow(song("Next"))             // a new song ends it
        #expect(store.syncing == nil)
    }

    /// Your report, 2026-11-17: one click had to be timed exactly. Now clicks refine each other (the middle one), and a
    /// click far from the rest (a wrong line) starts over.
    @Test func moreClicksRefineTheTiming() async {
        let store = makeStore(FakeLyricsService(answer: .found(lines)))
        store.follow(song(elapsed: 7.2, playing: false))
        await settle(store)
        store.startSync(in: .fullScreen)
        store.syncLine(shownAt: 10)                        // asks −3.0
        #expect(abs(store.timingOffset - -3.0) < 0.02)
        store.follow(song(elapsed: 7.6, playing: false))   // a late click on the same line: asks −2.6
        store.syncLine(shownAt: 7)
        #expect(abs(store.timingOffset - -2.8) < 0.02)     // the middle of the two
        store.follow(song(elapsed: 7.1, playing: false))   // asks −3.1
        store.syncLine(shownAt: 7.2)
        #expect(abs(store.timingOffset - -3.0) < 0.02)     // the middle of three: the late one no longer counts
        store.follow(song(elapsed: 12.2, playing: false))  // "a" (shown at 2.0) clicked at 12.2: asks +7.0, far off
        store.syncLine(shownAt: 2)
        #expect(abs(store.timingOffset - 5.0) < 0.02)      // starts over from it (and stops at the 5 s limit)
        #expect(LyricsStore.middle([3, 1, 2]) == 2)
        #expect(LyricsStore.middle([1, 2]) == 1.5)
    }

    @Test func aSavedFixIsAppliedWhenTheSongLoads() async {
        let store = makeStore(FakeLyricsService(answer: .found(lines), offset: 0.75))
        store.follow(song())
        await settle(store)
        #expect(store.timingOffset == 0.75)
        #expect(times(store.lyrics) == [5.75, 10.75])
    }

    @Test func fixesStopAtFiveSeconds() async {
        let store = makeStore(FakeLyricsService(answer: .found(lines)))
        store.follow(song())
        await settle(store)
        for _ in 0..<30 { store.nudge(by: 0.25) }
        #expect(store.timingOffset == 5)
    }

    @Test func noTimingMenuWithoutTimedLyrics() async {
        let store = makeStore(FakeLyricsService(answer: .found(.plain("words"))))
        store.follow(song())
        await settle(store)
        #expect(!store.canAdjustTiming)
        store.nudge(by: 0.25)
        #expect(store.timingOffset == 0)
    }

    @Test func findThenPickAVersion() async {
        let a = LyricsVersion(id: 1, lines: [LyricLine(time: 5, text: "a"), LyricLine(time: 10, text: "b")], record: Data())
        let b = LyricsVersion(id: 2, lines: [LyricLine(time: 4, text: "a"), LyricLine(time: 9, text: "b")], record: Data())
        let c = LyricsVersion(id: 3, lines: [LyricLine(time: 6, text: "a"), LyricLine(time: 11, text: "b")], record: Data())
        let fake = FakeLyricsService(answer: .found(lines), versions: .found([a, b, c]))
        let store = makeStore(fake)
        store.follow(song())
        await settle(store)
        store.nudge(by: 0.5)

        store.findVersions()                            // asks LRCLIB once; nothing changes yet
        for _ in 0..<50 where store.versionSearch == .searching { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(store.versionSearch == .found(current: 0, count: 3))
        #expect(times(store.lyrics) == [5.5, 10.5])
        #expect(store.versionComparison(1)?.shift == -1)   // b is 1 s earlier than a
        #expect(store.versionComparison(2)?.shift == 1)

        store.useVersion(1)
        #expect(times(store.lyrics) == [4, 9])
        #expect(store.timingOffset == 0)                // the fix belonged to the other version
        #expect(store.versionComparison(0)?.shift == 1)    // labels follow the version in use
        store.useVersion(2)
        #expect(times(store.lyrics) == [6, 11])
        store.findVersions()                            // already listed: no second request
        await flush()
        #expect(await fake.versionRequests == 1)
        #expect(await fake.used == [2, 3])
    }

    @Test func oneVersionMeansNoOthers() async {
        let only = LyricsVersion(id: 1, lines: [LyricLine(time: 5, text: "a")], record: Data())
        let store = makeStore(FakeLyricsService(answer: .found(lines), versions: .found([only])))
        store.follow(song())
        await settle(store)
        store.findVersions()
        for _ in 0..<50 where store.versionSearch == .searching { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(store.versionSearch == .found(current: 0, count: 1))
    }

    @Test func offlineVersionSearchCanBeRetried() async {
        let store = makeStore(FakeLyricsService(answer: .found(lines), versions: .offline))
        store.follow(song())
        await settle(store)
        store.findVersions()
        for _ in 0..<50 where store.versionSearch == .searching { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(store.versionSearch == .unavailable)
        store.findVersions()                            // asking again is allowed
        #expect(store.versionSearch == .searching)
    }

    @Test func aNewSongStartsWithoutTheOldFix() async {
        let store = makeStore(FakeLyricsService(answer: .found(lines)))
        store.follow(song("One"))
        await settle(store)
        store.nudge(by: 1)
        store.follow(song("Two"))
        #expect(store.timingOffset == 0)
        #expect(store.versionSearch == .idle)
    }

    @Test func menuTitlesSayWhatYouDid() {
        #expect(LyricsTimingMenuItems.resetTitle(offset: 0) == "Reset Timing")
        #expect(LyricsTimingMenuItems.resetTitle(offset: -0.5) == "Reset Timing (now −0.50 s)")
        #expect(LyricsTimingMenuItems.resetTitle(offset: 0.25) == "Reset Timing (now +0.25 s)")
        typealias C = LRCLIBVersions.Comparison
        #expect(LyricsTimingMenuItems.versionLabel(index: 1, comparison: C(shift: -0.43, coverage: 1), inUse: false) == "2 · 0.43 s earlier")
        #expect(LyricsTimingMenuItems.versionLabel(index: 4, comparison: C(shift: 0.5, coverage: 0.95), inUse: false) == "5 · 0.50 s later")
        #expect(LyricsTimingMenuItems.versionLabel(index: 5, comparison: C(shift: 0.01, coverage: 1), inUse: false) == "6 · same timing")
        #expect(LyricsTimingMenuItems.versionLabel(index: 3, comparison: C(shift: -0.43, coverage: 0.8), inUse: false) == "4 · 0.43 s earlier · some lines differ")
        #expect(LyricsTimingMenuItems.versionLabel(index: 6, comparison: C(shift: nil, coverage: 0.2), inUse: false) == "7 · other lyrics")
        #expect(LyricsTimingMenuItems.versionLabel(index: 0, comparison: nil, inUse: true) == "1 · in use")
    }

    // MARK: Word sweep

    /// Your pick, 2026-11-17: word by word only with real word timing; a line timed only as a whole lights up at once.
    /// The song is held still (paused) so the moment can't drift while the test runs: the old version of this test,
    /// with the song playing, failed once on a busy Mac.
    @Test func onlyRealWordTimingSweeps() async {
        let worded = Lyrics.synced([LyricLine(time: 5, text: "one two", marks: [WordMark(letter: 0, time: 5), WordMark(letter: 4, time: 6)]),
                                    LyricLine(time: 10, text: "b")])
        let store = makeStore(FakeLyricsService(answer: .found(worded)))
        store.beginDisplay()
        store.follow(NowPlaying(title: "Song", artist: "Artist", isPlaying: false, duration: 200, elapsed: 5.5, timestamp: .now))
        await settle(store)
        store.follow(NowPlaying(title: "Song", artist: "Artist", isPlaying: false, duration: 200, elapsed: 5.5, timestamp: .now))
        let clock = store.sweepClock
        #expect(clock?.line == 0 && clock?.playing == false)          // paused: the sweep holds still
        #expect((clock?.progress ?? 0) > 0 && (clock?.progress ?? 1) < 4.0 / 7)  // inside "one", before "two"
        store.endDisplay()

        let plain = makeStore(FakeLyricsService(answer: .found(lines)))  // line timing only
        plain.beginDisplay()
        plain.follow(NowPlaying(title: "Song", artist: "Artist", isPlaying: false, duration: 200, elapsed: 6, timestamp: .now))
        await settle(plain)
        plain.follow(NowPlaying(title: "Song", artist: "Artist", isPlaying: false, duration: 200, elapsed: 6, timestamp: .now))
        #expect(plain.currentIndex == 0 && plain.sweepClock == nil)   // the whole line lit, no guessed sweep
        plain.endDisplay()
    }

    @Test func switchingOffClearsEverything() async {
        let (store, _) = makeStore(answer: .found(lines))
        store.follow(song())
        await settle(store)
        store.setEnabled(false)
        #expect(store.status == .off)
        #expect(store.lyrics == nil)
    }

    // MARK: Shuffle and Output (your report, 2026-09-30: the full-screen lyrics went back to the top)

    @Test func theSameSongAnnouncedAgainKeepsItsLyricsAndPlace() async {
        let (store, fake) = makeStore(answer: .found(lines))
        store.follow(song(elapsed: 6))
        await settle(store)
        store.beginDisplay()
        #expect(store.currentIndex == 0)
        // What a player sends after Shuffle or an output switch: other case, an album, a slightly different length.
        store.follow(NowPlaying(title: "song", artist: "ARTIST", album: "Deluxe", isPlaying: true, duration: 200.4,
                                elapsed: 6.2, timestamp: .now))
        #expect(store.status == .ready)
        #expect(store.lyrics != nil)
        #expect(store.currentIndex == 0)                     // same line: nothing went back to the top
        #expect(await fake.requests.count == 1)              // not looked up again
        store.endDisplay()
    }

    @Test func aMomentaryBlankKeepsTheLyrics() async {
        let (store, fake) = makeStore(answer: .found(lines), grace: .milliseconds(200))
        store.follow(song(elapsed: 6))
        await settle(store)
        store.beginDisplay()
        store.follow(nil)                                    // the player drops out for a moment
        #expect(store.status == .ready)
        #expect(store.currentIndex == 0)
        store.follow(song(elapsed: 6.3))                     // and is back
        try? await Task.sleep(for: .milliseconds(350))       // past the grace: it must not clear now
        #expect(store.status == .ready)
        #expect(store.currentIndex == 0)
        #expect(await fake.requests.count == 1)
        store.endDisplay()
    }

    @Test func aLongBlankClearsTheLyrics() async {
        let (store, _) = makeStore(answer: .found(lines), grace: .milliseconds(50))
        store.follow(song())
        await settle(store)
        store.follow(nil)
        for _ in 0..<50 where store.status != .none { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(store.status == .none)
        #expect(store.lyrics == nil)
    }

    @Test func anotherSongDuringABlankSwitchesAtOnce() async {
        let (store, fake) = makeStore(answer: .found(lines))
        store.follow(song("One"))
        await settle(store)
        store.follow(nil)
        store.follow(song("Two"))
        #expect(store.lyrics == nil)                         // no waiting, no stale lines
        #expect(store.status == .loading)
        await settle(store)
        #expect(await fake.requests.count == 2)
    }

    @Test func aDifferentLengthIsADifferentSong() async {
        let (store, fake) = makeStore(answer: .found(lines))
        store.follow(song(duration: 200))
        await settle(store)
        store.follow(song(duration: 260))                    // same name, another cut (a live or extended version)
        #expect(store.status == .loading)
        await settle(store)
        #expect(await fake.requests.count == 2)
    }

    @Test func switchingOffDuringABlankStaysOff() async {
        let (store, _) = makeStore(answer: .found(lines), grace: .milliseconds(50))
        store.follow(song())
        await settle(store)
        store.follow(nil)
        store.setEnabled(false)
        try? await Task.sleep(for: .milliseconds(150))       // the cancelled wait must not overwrite "off"
        #expect(store.status == .off)
    }
}

struct SameSongTests {
    private let query = LyricsQuery(title: "Glass Harbor", artist: "Wren", album: "Single", duration: 180)

    private func item(_ title: String = "Glass Harbor", artist: String? = "Wren", album: String? = "Single",
                      duration: TimeInterval? = 180) -> NowPlaying {
        NowPlaying(title: title, artist: artist, album: album, duration: duration)
    }

    @Test func noiseStillCountsAsTheSameSong() {
        #expect(query.isSameSong(as: item("glass harbor ", artist: "WREN")))
        #expect(query.isSameSong(as: item(album: nil)))
        #expect(query.isSameSong(as: item(album: "Glass Harbor (Deluxe)")))
        #expect(query.isSameSong(as: item(duration: 181.9)))
        #expect(query.isSameSong(as: item(artist: nil, duration: nil)))   // missing details don't count against it
    }

    @Test func anotherSongIsNot() {
        #expect(!query.isSameSong(as: item("Something Else")))
        #expect(!query.isSameSong(as: item(artist: "Someone Else")))
        #expect(!query.isSameSong(as: item(duration: 185)))
    }

    @Test func differencesNameFieldsOnly() {
        #expect(query.differences(from: item()).isEmpty)
        #expect(query.differences(from: item("glass harbor", album: nil, duration: 180.4)) == ["title", "album", "length"])
    }
}

struct LyricsDisplayTests {
    private let lines = Lyrics.synced([LyricLine(time: 5, text: "first"), LyricLine(time: 10, text: ""),
                                       LyricLine(time: 15, text: "third")])

    @Test func currentLineBrightNextLineDim() {
        let display = LyricsDisplay.make(status: .ready, lyrics: lines, currentIndex: 0, song: "S · A")
        #expect(display == LyricsDisplay(primary: "first", secondary: "third", style: .line,
                                         primaryTime: 5, secondaryTime: 15))  // skips the gap
    }

    /// A click on a line jumps to where it starts; the "♪" note has no line to jump to.
    @Test func clickTargetsAreTheLinesStartTimes() {
        let gap = LyricsDisplay.make(status: .ready, lyrics: lines, currentIndex: 1, song: "")
        #expect(gap.primaryTime == nil)
        #expect(gap.secondaryTime == 15)
        let intro = LyricsDisplay.make(status: .ready, lyrics: lines, currentIndex: nil, song: "")
        #expect(intro.primaryTime == nil)
        #expect(intro.secondaryTime == 5)
        let message = LyricsDisplay.make(status: .loading, lyrics: nil, currentIndex: nil, song: "S · A")
        #expect(message.primaryTime == nil && message.secondaryTime == nil)
    }

    @Test func gapsAndTheIntroShowANote() {
        #expect(LyricsDisplay.make(status: .ready, lyrics: lines, currentIndex: 1, song: "").primary == "♪")
        let intro = LyricsDisplay.make(status: .ready, lyrics: lines, currentIndex: nil, song: "")
        #expect(intro.primary == "♪")
        #expect(intro.secondary == "first")  // what's coming
    }

    @Test func messagesKeepTheSongUnderneath() {
        let display = LyricsDisplay.make(status: .notFound, lyrics: nil, currentIndex: nil, song: "Lantern · Milo Hart")
        #expect(display == LyricsDisplay(primary: "Oops, you caught us. No lyrics for this one yet.", secondary: "Lantern · Milo Hart", style: .status))
        #expect(LyricsDisplay.make(status: .ready, lyrics: .instrumental, currentIndex: nil, song: "").primary == "♪ Instrumental")
    }

    @Test func lastLineHasNothingNext() {
        #expect(LyricsDisplay.make(status: .ready, lyrics: lines, currentIndex: 2, song: "").secondary == nil)
    }
}

/// Your screenshot (2026-10-01): a long lyric line ended in "…" in the open island. Rendered at a 240 pt text width:
/// the bottom of the area holds the dim next line (38%), or the long line's own third line (fully lit).
@MainActor
struct LyricLinesTests {
    private func bottomAlpha(current: String, next: String?) -> (height: Int, alpha: Double) {
        let renderer = ImageRenderer(content: LyricLines(current: current, next: next)
            .frame(width: 240, alignment: .leading)
            .environment(\.colorScheme, .light))
        renderer.scale = 1
        guard let image = renderer.cgImage, let alpha = SweepLayerView.alpha(of: image) else { return (0, 0) }
        // Rows 44–54: where the next line sits under two lines, and where a third line of the current one sits.
        let rows = (44..<min(55, image.height)).flatMap { row in alpha[(row * image.width)..<((row + 1) * image.width)] }
        return (image.height, Double(rows.max() ?? 0) / 255)
    }

    @Test func aTwoLineLyricKeepsTheNextLine() {
        let shown = bottomAlpha(current: "A made-up line that wraps onto two lines here", next: "The next one")
        #expect(shown.height <= 58)  // the same room as before
        #expect(shown.alpha > 0.2 && shown.alpha < 0.5)  // the dim next line
    }

    @Test func aLongLyricTakesTheNextLinesPlace() {
        let long = "A made-up lyric line that is long enough to need three whole lines at the island's width"
        let shown = bottomAlpha(current: long, next: "The next one")
        #expect(shown.height <= 58)  // the island doesn't grow
        #expect(shown.alpha > 0.7)  // the long line's third line (bright; 0.85 at 1×), not the next line (≤ 0.38)
    }
}

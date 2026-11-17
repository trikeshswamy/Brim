import Foundation
import Testing
@testable import BrimCore

/// Brim rests asleep when nothing plays (instead of vanishing), and the one-time tips come in order, one per opening.
struct RestingAndTipsTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func restsAsThePillWhenNothingPlays() {
        var state = IslandState()
        state.idleStyle = .asleep
        #expect(IslandRules.surface(for: state, at: t0) == .compact(.resting))
        state.idleStyle = .hidden
        #expect(IslandRules.surface(for: state, at: t0) == .hidden)
    }

    /// Its own choice: music as the slim line doesn't put Brim's rest on the line too (your Mac, 2026-11-11).
    @Test func restingHasItsOwnChoice() {
        var state = IslandState()
        state.idleStyle = .asleep
        state.keptStyle = .slimLine
        #expect(IslandRules.surface(for: state, at: t0) == .compact(.resting))
        state.idleStyle = .slimLine
        state.keptStyle = .pill
        #expect(IslandRules.surface(for: state, at: t0) == .slim)
    }

    /// Where a Focus or a full-screen window asks for the line, Brim never rests as the pill.
    @Test func theLineWhereItIsAskedFor() {
        var state = IslandState()
        state.idleStyle = .asleep
        state.focusIsland = .slimLine
        #expect(IslandRules.surface(for: state, at: t0) == .slim)
        state.focusIsland = nil
        state.frontIsFullScreen = true
        state.fullScreen = .slimLine
        #expect(IslandRules.surface(for: state, at: t0) == .slim)
    }

    @Test func musicTimersAndKeepAwakeComeFirst() {
        var state = IslandState()
        state.idleStyle = .asleep
        state.keepPillVisible = true
        state.media = .playing
        #expect(IslandRules.surface(for: state, at: t0) == .compact(.keptMusic))
        state.media = .none
        state.keepAwake = true
        #expect(IslandRules.surface(for: state, at: t0) == .compact(.keepAwake))
        state.timerRunning = true
        #expect(IslandRules.surface(for: state, at: t0) == .compact(.timer))
    }

    /// "Keep music visible" off means no pill over your music: Brim doesn't rest there either.
    @Test func noRestingPillOverMusicYouChoseToHide() {
        var state = IslandState()
        state.idleStyle = .asleep
        state.keepPillVisible = false
        state.media = .playing
        #expect(IslandRules.surface(for: state, at: t0) == .hidden)
    }

    @Test func pausedMusicRestsAfterItsMinute() {
        var state = IslandState()
        state.idleStyle = .asleep
        state.keepPillVisible = true
        state.media = .paused(since: t0)
        #expect(IslandRules.surface(for: state, at: t0.addingTimeInterval(59)) == .compact(.keptMusic))
        #expect(IslandRules.surface(for: state, at: t0.addingTimeInterval(61)) == .compact(.resting))
    }

    @Test func fullScreenAndAHidingFocusStayClear() {
        var state = IslandState()
        state.idleStyle = .asleep
        state.frontIsFullScreen = true
        #expect(IslandRules.surface(for: state, at: t0) == .hidden)
        state.frontIsFullScreen = false
        state.focusIsland = .hidden
        #expect(IslandRules.surface(for: state, at: t0) == .hidden)
    }

    @Test func restingNeverInterruptsOrWaits() {
        #expect(!IslandActivity.Kind.resting.getsThroughFocus)
    }

    // MARK: Tips

    @Test func tipsComeInOrderOnePerOpening() {
        var seen: Set<String> = []
        #expect(TipRules.next(seen: seen, page: .calendar, hasSong: false, lyricsShowing: false) == .menu)
        seen.insert("menu")
        #expect(TipRules.next(seen: seen, page: .calendar, hasSong: false, lyricsShowing: false) == nil)
        #expect(TipRules.next(seen: seen, page: .music, hasSong: true, lyricsShowing: false) == .cover)
        seen.insert("cover")
        #expect(TipRules.next(seen: seen, page: .music, hasSong: true, lyricsShowing: true) == .swipe)
        seen.insert("swipe")
        #expect(TipRules.next(seen: seen, page: .music, hasSong: true, lyricsShowing: false) == nil)
        #expect(TipRules.next(seen: seen, page: .music, hasSong: true, lyricsShowing: true) == .lyrics)
        seen.insert("lyrics")
        #expect(TipRules.next(seen: seen, page: .music, hasSong: true, lyricsShowing: true) == nil)
    }

    @Test func aTipOnlyWhereItsThingIsOnScreen() {
        let seen: Set<String> = ["menu"]
        #expect(TipRules.next(seen: seen, page: .music, hasSong: false, lyricsShowing: false) == nil)
        #expect(TipRules.next(seen: seen, page: .timers, hasSong: true, lyricsShowing: true) == nil)
    }

    @Test func everyTipIsOneShortLine() {
        for tip in Tip.allCases {
            #expect(tip.text.count <= 52 && !tip.text.contains("\n"))
        }
    }
}

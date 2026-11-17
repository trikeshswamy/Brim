import Foundation
import Testing
@testable import BrimCore

struct IslandRulesTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func hiddenWhenNothingHappens() {
        #expect(IslandRules.surface(for: IslandState(), at: t0) == .hidden)
        #expect(IslandRules.nextChange(for: IslandState(), after: t0) == nil)
    }

    @Test func trackChangeShowsCompactForThreeSeconds() {
        var state = IslandState()
        state.activities = [.nowPlaying(at: t0)]
        #expect(IslandRules.surface(for: state, at: t0.addingTimeInterval(2.9)) == .compact(.nowPlaying))
        #expect(IslandRules.surface(for: state, at: t0.addingTimeInterval(3.0)) == .hidden)
        #expect(IslandRules.nextChange(for: state, after: t0) == t0.addingTimeInterval(3))
    }

    @Test func hoverExpandsToMediaOrIdle() {
        var state = IslandState()
        state.isHovering = true
        #expect(IslandRules.surface(for: state, at: t0) == .expanded(.calendar))
        state.media = .playing
        #expect(IslandRules.surface(for: state, at: t0) == .expanded(.music))
    }

    @Test func hoverBeatsActivitiesIncludingTheHUD() {
        var state = IslandState()
        state.activities = [.nowPlaying(at: t0), .hud(.volume, at: t0)]
        state.isHovering = true
        state.media = .playing
        // While you hover, the HUD shows inside the open island; the island stays open.
        #expect(IslandRules.surface(for: state, at: t0) == .expanded(.music))
    }

    @Test func staysOpenForTheGraceAfterThePointerLeaves() {
        var state = IslandState()
        state.hoverEndedAt = t0
        #expect(IslandRules.surface(for: state, at: t0.addingTimeInterval(0.5)) == .expanded(.calendar))
        #expect(IslandRules.surface(for: state, at: t0.addingTimeInterval(0.6)) == .hidden)
        #expect(IslandRules.nextChange(for: state, after: t0) == t0.addingTimeInterval(IslandRules.hoverGrace))
    }

    @Test func hudBeatsTheTrackChangeThenDisappearsAfterOneAndAHalfSeconds() {
        var state = IslandState()
        state.activities = [.nowPlaying(at: t0), .hud(.volume, at: t0)]
        #expect(IslandRules.surface(for: state, at: t0.addingTimeInterval(1)) == .compact(.hud(.volume)))
        #expect(IslandRules.surface(for: state, at: t0.addingTimeInterval(2)) == .compact(.nowPlaying))
    }

    @Test func higherPriorityWinsAndNewestBreaksTies() {
        let old = IslandActivity(kind: .nowPlaying, priority: 10, start: t0, duration: 10)
        let new = IslandActivity(kind: .nowPlaying, priority: 10, start: t0.addingTimeInterval(1), duration: 10)
        let urgent = IslandActivity(kind: .hud(.volume), priority: 90, start: t0, duration: 10)
        let ordered = IslandRules.liveActivities([old, new, urgent], at: t0.addingTimeInterval(2))
        #expect(ordered.map(\.priority) == [90, 10, 10])
        #expect(ordered[1].start == new.start)
    }

    @Test func expiredActivitiesAreDropped() {
        let stale = IslandActivity(kind: .nowPlaying, priority: 10, start: t0, duration: 3)
        #expect(IslandRules.liveActivities([stale], at: t0.addingTimeInterval(4)).isEmpty)
    }

    // MARK: Kept-visible pill

    @Test func keptPillStaysWhilePlaying() {
        var state = IslandState()
        state.keepPillVisible = true
        state.media = .playing
        #expect(IslandRules.surface(for: state, at: t0.addingTimeInterval(3600)) == .compact(.keptMusic))
    }

    @Test func keptPillHidesOneMinuteAfterPausing() {
        var state = IslandState()
        state.keepPillVisible = true
        state.media = .paused(since: t0)
        #expect(IslandRules.surface(for: state, at: t0.addingTimeInterval(59)) == .compact(.keptMusic))
        #expect(IslandRules.surface(for: state, at: t0.addingTimeInterval(60)) == .hidden)
        #expect(IslandRules.nextChange(for: state, after: t0) == t0.addingTimeInterval(60))
    }

    @Test func pillIsNotKeptWhenTheSettingIsOff() {
        var state = IslandState()
        state.media = .playing
        #expect(IslandRules.surface(for: state, at: t0) == .hidden)
    }

    // MARK: Slim line

    @Test func slimLineShowsInsteadOfThePill() {
        var state = IslandState()
        state.keepPillVisible = true
        state.keptStyle = .slimLine
        state.media = .playing
        #expect(IslandRules.surface(for: state, at: t0) == .slim)
    }

    /// Feature 2 (your picks, 2026-10-02): a macOS Focus's Brim filter sets the island; full screen still wins.
    @Test func aFocusFilterSetsTheIsland() {
        var state = IslandState()
        state.keepPillVisible = true
        state.media = .playing
        state.focusIsland = .slimLine
        #expect(IslandRules.surface(for: state, at: t0) == .slim)
        state.focusIsland = .hidden
        #expect(IslandRules.surface(for: state, at: t0) == .hidden)              // nothing rests
        state.activities = [.calendar(at: t0)]
        #expect(IslandRules.surface(for: state, at: t0) == .compact(.calendar))  // glances still show
        state.activities = []
        state.isHovering = true
        #expect(IslandRules.surface(for: state, at: t0) == .expanded(.music))    // and it still opens
        state.isHovering = false
        state.keptStyle = .slimLine
        state.focusIsland = .pill
        #expect(IslandRules.surface(for: state, at: t0) == .compact(.keptMusic)) // the Focus's pick over yours
        state.frontIsFullScreen = true
        #expect(IslandRules.surface(for: state, at: t0) == .hidden)              // full screen kept clear (default)
        state.fullScreen = .slimLine
        #expect(IslandRules.surface(for: state, at: t0) == .slim)                // or the line: never the pill there
        state.focusIsland = nil
        state.frontIsFullScreen = false
        #expect(IslandRules.surface(for: state, at: t0) == .slim)                // Focus off: your setting again
    }

    /// Your reports (2026-10-02): over a full-screen app the pill drew the eye, and in a full-screen video even the
    /// slim line did. By default nothing rests there; the slim line is the other choice.
    @Test func aFullScreenAppIsKeptClear() {
        var state = IslandState()
        state.keepPillVisible = true
        state.media = .playing
        state.timerRunning = true
        #expect(IslandRules.surface(for: state, at: t0) == .compact(.keptMusic))
        state.frontIsFullScreen = true
        #expect(state.fullScreen == .hide)                                     // the default
        #expect(IslandRules.surface(for: state, at: t0) == .hidden)            // no pill, no line, no timer mark
        #expect(state.quiet)                                                  // only important notices
        state.activities = [.calendar(at: t0)]
        #expect(IslandRules.surface(for: state, at: t0) == .compact(.calendar))  // a class reminder still shows
        state.activities = []
        state.isHovering = true
        #expect(IslandRules.surface(for: state, at: t0) == .expanded(.music))  // and it still opens from the top
        state.isHovering = false
        state.fullScreen = .slimLine                                         // your other choice
        #expect(!state.quiet)
        #expect(IslandRules.surface(for: state, at: t0) == .slim)
        state.media = .none
        #expect(IslandRules.surface(for: state, at: t0) == .slim)              // the timer rides on the line as a mark
        state.frontIsFullScreen = false
        #expect(IslandRules.surface(for: state, at: t0) == .compact(.timer))   // out of full screen: as usual
    }

    @Test func songChangeShowsTheFullPillThenTheSlimLineReturns() {
        var state = IslandState()
        state.keepPillVisible = true
        state.keptStyle = .slimLine
        state.media = .playing
        state.activities = [.nowPlaying(at: t0)]
        #expect(IslandRules.surface(for: state, at: t0.addingTimeInterval(1)) == .compact(.nowPlaying))
        #expect(IslandRules.surface(for: state, at: t0.addingTimeInterval(3)) == .slim)
    }

    @Test func slimLineOpensLikeThePillAndHidesAMinuteAfterPausing() {
        var state = IslandState()
        state.keepPillVisible = true
        state.keptStyle = .slimLine
        state.media = .paused(since: t0)
        #expect(IslandRules.surface(for: state, at: t0.addingTimeInterval(59)) == .slim)
        #expect(IslandRules.surface(for: state, at: t0.addingTimeInterval(60)) == .hidden)
        state.isHovering = true
        #expect(IslandRules.surface(for: state, at: t0) == .expanded(.music))
    }

    @Test func fullScreenPlayerHidesEverything() {
        var state = IslandState()
        state.keepPillVisible = true
        state.media = .playing
        state.activities = [.hud(.volume, at: t0)]
        state.fullScreenPlayerOpen = true
        #expect(IslandRules.surface(for: state, at: t0) == .hidden)
    }

    @Test func welcomeTakesTheIslandsPlaceEvenUnderThePointer() {
        var state = IslandState()
        state.keepPillVisible = true
        state.media = .playing
        state.activities = [.hud(.volume, at: t0)]
        state.isHovering = true
        state.welcomeOpen = true
        #expect(IslandRules.surface(for: state, at: t0) == .hidden)
        state.welcomeOpen = false
        #expect(IslandRules.surface(for: state, at: t0) == .expanded(.music))
    }

    @Test func hudShowsOverTheKeptPillThenThePillReturns() {
        var state = IslandState()
        state.keepPillVisible = true
        state.media = .playing
        state.activities = [.hud(.volume, at: t0)]
        #expect(IslandRules.surface(for: state, at: t0.addingTimeInterval(1)) == .compact(.hud(.volume)))
        #expect(IslandRules.surface(for: state, at: t0.addingTimeInterval(2)) == .compact(.keptMusic))
    }
}

struct BrightnessStateTests {
    @Test func sunGrowsFromHalf() {
        #expect(BrightnessState(level: 0.2).symbolName == "sun.min.fill")
        #expect(BrightnessState(level: 0.5).symbolName == "sun.max.fill")
    }
}

struct VolumeStateTests {
    @Test func symbolFollowsLevelInThirds() {
        #expect(VolumeState(level: 0, isMuted: false).symbolName == "speaker.slash.fill")
        #expect(VolumeState(level: 0.2, isMuted: false).symbolName == "speaker.wave.1.fill")
        #expect(VolumeState(level: 0.5, isMuted: false).symbolName == "speaker.wave.2.fill")
        #expect(VolumeState(level: 0.9, isMuted: false).symbolName == "speaker.wave.3.fill")
        #expect(VolumeState(level: 0.9, isMuted: true).symbolName == "speaker.slash.fill")
    }
}

struct CalendarRulesTests {
    @Test func switchedOffCalendarsAreLeftOut() {
        let t0 = Date()
        let events = [CalendarEvent(id: "1", title: "A", start: t0, end: t0, calendarID: "holidays"),
                      CalendarEvent(id: "2", title: "B", start: t0, end: t0, calendarID: "work"),
                      CalendarEvent(id: "3", title: "C", start: t0, end: t0)]          // unknown calendar: stays
        #expect(CalendarRules.visible(events, hidden: ["holidays"]).map(\.id) == ["2", "3"])
        #expect(CalendarRules.visible(events, hidden: []).count == 3)
    }

    /// Your question (2026-10-05): a click on an event opens it in Apple's Calendar app.
    @Test func anEventOpensInAppleCalendar() {
        #expect(CalendarEvent.calendarAppURL(itemID: "4F0A9C2E-1D2B-4C3A-9E8F-ABCDEF012345")?.absoluteString
                == "ical://ekevent/4F0A9C2E-1D2B-4C3A-9E8F-ABCDEF012345")   // the link MeetingBar uses
        #expect(CalendarEvent.calendarAppURL(itemID: "a b")?.absoluteString == "ical://ekevent/a%20b")  // encoded
        #expect(CalendarEvent.calendarAppURL(itemID: "") == nil)                // nothing to open: not a button
    }

    /// Your time zone, so "today" means the same day it does for you.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int, day: Int = 30) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func event(_ id: String, _ start: Date, minutes: Double = 60, allDay: Bool = false, declined: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, title: id, start: start, end: start.addingTimeInterval(minutes * 60), isAllDay: allDay, declined: declined)
    }

    @Test func theNextEventIsTimedNotDeclinedAndToday() {
        let now = at(15, 24)
        let events = [
            event("ended", at(13, 0)),
            event("all day", at(0, 0), minutes: 24 * 60, allDay: true),
            event("declined", at(15, 40), declined: true),
            event("later", at(18, 0)),
            event("lecture", at(16, 0)),
            event("tomorrow", at(9, 0, day: 31)),
        ]
        #expect(CalendarRules.next(in: events, now: now, calendar: calendar)?.id == "lecture")
        // During the lecture it stays until it ends.
        #expect(CalendarRules.next(in: events, now: at(16, 30), calendar: calendar)?.id == "lecture")
        #expect(CalendarRules.next(in: events, now: at(20, 0), calendar: calendar) == nil)  // "Nothing else today"
    }

    @Test func countdowns() {
        let start = at(16, 0)
        #expect(CalendarRules.countdown(to: start, now: at(15, 24)) == "in 36 min")
        #expect(CalendarRules.countdown(to: start, now: at(15, 55)) == "in 5 min")
        #expect(CalendarRules.countdown(to: start, now: at(15, 55).addingTimeInterval(0.2)) == "in 5 min")  // a late reminder
        #expect(CalendarRules.countdown(to: start, now: at(15, 0)) == "in 1 h")
        #expect(CalendarRules.countdown(to: start, now: at(14, 40)) == "in 1 h 20 min")
        #expect(CalendarRules.countdown(to: start, now: at(16, 1)) == "now")
    }

    @Test func remindersComeFiveMinutesBefore() {
        let now = at(15, 24)
        let lecture = event("lecture", at(16, 0))
        #expect(CalendarRules.nextReminder(in: [lecture], now: now, shown: [])?.at == at(15, 55))
        // Inside the 5 minutes already (just added, or Brim just started): straight away.
        #expect(CalendarRules.nextReminder(in: [lecture], now: at(15, 57), shown: [])?.at == at(15, 57))
        #expect(CalendarRules.nextReminder(in: [lecture], now: now, shown: ["lecture"]) == nil)
        let quiet = [event("all day", at(16, 0), allDay: true), event("declined", at(16, 0), declined: true)]
        #expect(CalendarRules.nextReminder(in: quiet, now: now, shown: []) == nil)
    }

    @Test func theAgendaIsTodayInOrder() {
        let events = [
            event("later", at(18, 0)), event("ended", at(13, 0)), event("declined", at(15, 40), declined: true),
            event("all day", at(0, 0), minutes: 24 * 60, allDay: true), event("tomorrow", at(9, 0, day: 31)),
            event("now", at(15, 0)),
        ]
        #expect(CalendarRules.agenda(in: events, now: at(15, 24), calendar: calendar).map(\.id) == ["ended", "now", "later"])
    }

    @Test func meetingLinks() {
        #expect(MeetingLink.find(in: [nil, "Join: https://us02web.zoom.us/j/123?pwd=x"])?.host == "us02web.zoom.us")
        #expect(MeetingLink.find(in: ["meet.google.com/abc-defg-hij"])?.host == "meet.google.com")
        #expect(MeetingLink.find(in: ["https://teams.microsoft.com/l/meetup-join/1"]) != nil)
        #expect(MeetingLink.find(in: ["Room 204", "https://example.com/notes"]) == nil)
    }
}

struct TimerTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func runsPausesAndAddsAMinute() {
        let timer = TimerState.start(length: 25 * 60, at: t0)
        #expect(TimerRules.clock(timer.remaining(at: t0)) == "25:00")
        #expect(TimerRules.clock(timer.remaining(at: t0.addingTimeInterval(47))) == "24:13")
        #expect(TimerRules.bubbleLabel(timer.remaining(at: t0.addingTimeInterval(47))) == "24")
        let paused = timer.paused(at: t0.addingTimeInterval(60))
        #expect(paused.remaining(at: t0.addingTimeInterval(600)) == 24 * 60)  // time stops while paused
        let resumed = paused.resumed(at: t0.addingTimeInterval(600))
        #expect(resumed.endsAt == t0.addingTimeInterval(600 + 24 * 60))
        let longer = resumed.addingMinute()
        #expect(longer.total == 26 * 60 && longer.lengthText == "26 min")
        #expect(longer.remaining(at: t0.addingTimeInterval(600)) == 25 * 60)
        #expect(timer.hasEnded(at: t0.addingTimeInterval(25 * 60)))
        #expect(!paused.hasEnded(at: t0.addingTimeInterval(99_999)))
    }

    @Test func lastMinuteShowsSeconds() {
        #expect(TimerRules.bubbleLabel(60) == "1")
        #expect(TimerRules.bubbleLabel(59.2) == "1")    // the clock still reads 1:00
        #expect(TimerRules.bubbleLabel(59) == "59s")
        #expect(TimerRules.bubbleLabel(0.3) == "1s")
        #expect(TimerState(total: 100, endsAt: nil).lengthText == "1 min 40 s")
        #expect(TimerState(total: 25 * 60, endsAt: nil).lengthText == "25 min")
        #expect(TimerState(total: 45, endsAt: nil).lengthText == "45 s")
    }

    @Test func noticesAtFiveAndOneMinuteLeft() {
        let timer = TimerState.start(length: 25 * 60, at: t0)
        let first = TimerRules.nextMilestone(for: timer, at: t0, shown: [])
        #expect(first?.minutes == 5 && first?.at == t0.addingTimeInterval(20 * 60))
        #expect(TimerRules.nextMilestone(for: timer, at: t0, shown: [5])?.minutes == 1)
        // A 5-minute timer doesn't say "5 min left" as it starts.
        let short = TimerState.start(length: 5 * 60, at: t0)
        #expect(TimerRules.nextMilestone(for: short, at: t0, shown: [])?.minutes == 1)
        #expect(TimerRules.nextMilestone(for: timer.paused(at: t0), at: t0, shown: []) == nil)
    }

    @Test func theTimerTakesTheCentreWhenMusicHides() {
        var state = IslandState()
        state.timerRunning = true  // shown by default (2026-09-30)
        #expect(IslandRules.surface(for: state, at: t0) == .compact(.timer))
        state.keepPillVisible = true
        state.media = .playing
        #expect(IslandRules.surface(for: state, at: t0) == .compact(.keptMusic))  // the ring sits beside it
        state.keptStyle = .slimLine
        #expect(IslandRules.surface(for: state, at: t0) == .slim)                // your cover-nothing choice holds
        state.activities = [.timerDone(at: t0)]
        #expect(IslandRules.surface(for: state, at: t0.addingTimeInterval(29)) == .compact(.timerDone))
    }

    @Test func theBubbleOpensTheTimerPage() {
        var state = IslandState()
        state.media = .playing
        state.isHovering = true
        state.openPage = .timers
        #expect(IslandRules.surface(for: state, at: t0) == .expanded(.timers))
    }
}

/// Decision 9 (your fix round, 2026-09-30): a swipe hides only the side bubbles, never the pill.
/// Your fix round 2, item 6 (pick A): with the slim line, Live Activities stay on the line as marks.
struct SlimActivitiesTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func withTheSlimLineATimerStaysOnTheLine() {
        var state = IslandState()
        state.keptStyle = .slimLine
        state.timerRunning = true
        #expect(IslandRules.surface(for: state, at: t0) == .slim)          // not the timer pill over your toolbar
        state.timerRunning = false
        state.keepAwake = true
        #expect(IslandRules.surface(for: state, at: t0) == .slim)          // not the coffee pill either
        state.keepAwake = false
        #expect(IslandRules.surface(for: state, at: t0) == .hidden)
    }

    @Test func withThePillNothingChanges() {
        var state = IslandState()
        state.timerRunning = true
        #expect(IslandRules.surface(for: state, at: t0) == .compact(.timer))
        state.timerRunning = false
        state.keepAwake = true
        #expect(IslandRules.surface(for: state, at: t0) == .compact(.keepAwake))
    }
}

struct PillSwipeTests {
    @Test func bubblesRideOnlyBesideARestingPill() {
        #expect(SideRules.showsBubbles(beside: .compact(.keptMusic)))
        #expect(SideRules.showsBubbles(beside: .compact(.timer)))
        #expect(SideRules.showsBubbles(beside: .compact(.hud(.volume))))
        #expect(!SideRules.showsBubbles(beside: .compact(.keepAwake)))    // the coffee pill on its own
        #expect(!SideRules.showsBubbles(beside: .compact(.nowPlaying)))   // a glance
        #expect(!SideRules.showsBubbles(beside: .slim))
        #expect(!SideRules.showsBubbles(beside: .expanded(.music)))
    }

    @Test func somethingStartingBringsBackOnlyItsSide() {
        let a = UUID(), b = UUID()
        let before = SideRules.activities(keepAwake: false, timers: [a], soonEvent: nil)
        #expect(SideRules.newSides(SideRules.activities(keepAwake: false, timers: [a, b], soonEvent: nil), since: before) == [.right])
        #expect(SideRules.newSides(SideRules.activities(keepAwake: true, timers: [a], soonEvent: nil), since: before) == [.left])
        #expect(SideRules.newSides(SideRules.activities(keepAwake: false, timers: [a], soonEvent: "class"), since: before) == [.right])
        #expect(SideRules.newSides(SideRules.activities(keepAwake: false, timers: [], soonEvent: nil), since: before).isEmpty)
        #expect(SideRules.newSides(before, since: before).isEmpty)
    }

    /// Your fix round 2 (item 5): the swipe acts on the bubble your fingers are on.
    @Test func aSwipeOnABubbleHidesOnlyThatOne() {
        let both = SideBubbles(left: true, right: .timer(UUID()), more: 1)
        #expect(SideRules.afterSwipe(on: .right, available: both, hidden: []) == [.right])      // the timer goes
        #expect(SideRules.afterSwipe(on: .left, available: both, hidden: [.right]) == [.left, .right])
        #expect(SideRules.afterSwipe(on: .right, available: both, hidden: [.right]) == nil)     // already gone: no tick
        #expect(SideRules.afterSwipe(on: nil, available: both, hidden: [.right]) == [])         // the pill: all back
        #expect(SideRules.afterSwipe(on: nil, available: both, hidden: []) == [.left, .right])  // all showing: all hide
        let coffeeOnly = SideBubbles(left: true)
        #expect(SideRules.afterSwipe(on: nil, available: coffeeOnly, hidden: [.right])
                == [.left, .right])                                                              // its timers ended
        #expect(SideRules.afterSwipe(on: nil, available: .none, hidden: []) == nil)             // nothing to show: no tick
        #expect(both.hiding([.right]) == SideBubbles(left: true))                                // "+N" goes with it
    }

    /// Nothing in the island's state hides the pill any more: music with a timer rests as the music pill.
    @Test func musicWithATimerRestsAsThePill() {
        var state = IslandState()
        state.keepPillVisible = true
        state.media = .playing
        state.timerRunning = true
        #expect(IslandRules.surface(for: state, at: Date(timeIntervalSince1970: 1_000)) == .compact(.keptMusic))
    }
}

struct PageSwitchRulesTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func theTabsPickThePage() {
        var state = IslandState()
        state.media = .playing
        state.isHovering = true
        #expect(IslandRules.surface(for: state, at: t0) == .expanded(.music))     // something plays: Music
        state.openPage = .timers
        #expect(IslandRules.surface(for: state, at: t0) == .expanded(.timers))    // you picked Timers
        state.openPage = nil
        state.media = .none
        #expect(IslandRules.surface(for: state, at: t0) == .expanded(.calendar))  // nothing plays: your last tab
        state.lastTab = .timers
        #expect(IslandRules.surface(for: state, at: t0) == .expanded(.timers))
        state.lastTab = .music
        #expect(IslandRules.surface(for: state, at: t0) == .expanded(.calendar))  // never an empty Music tab by itself
    }
}

struct GlanceQueueTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func importantGlancesWaitTheirTurn() {
        // Your reminder arrives while you change the volume: it shows after the HUD, for its full 6 s.
        var activities = [IslandActivity.hud(.volume, at: t0), .calendar(at: t0.addingTimeInterval(0.5))]
        activities = IslandRules.queued(activities, at: t0.addingTimeInterval(0.5))
        let reminder = activities.first { $0.kind == .calendar }
        #expect(reminder?.start == t0.addingTimeInterval(1.5))  // when the HUD ends
        var state = IslandState()
        state.activities = activities
        #expect(IslandRules.surface(for: state, at: t0.addingTimeInterval(1)) == .compact(.hud(.volume)))
        #expect(IslandRules.surface(for: state, at: t0.addingTimeInterval(7)) == .compact(.calendar))  // 1.5 + 6 > 7
    }

    @Test func aSongChangeDoesntWait() {
        let activities = IslandRules.queued([.hud(.volume, at: t0), .nowPlaying(at: t0)], at: t0)
        var state = IslandState()
        state.activities = activities
        #expect(IslandRules.surface(for: state, at: t0.addingTimeInterval(3.5)) == .hidden)  // it simply passed
    }

    @Test func twoWaitingGlancesTakeTurns() {
        var activities = [IslandActivity.hud(.volume, at: t0), .calendar(at: t0), .battery(at: t0)]
        activities = IslandRules.queued(activities, at: t0)
        // After the HUD (1.5 s): the reminder first (higher), then the battery notice after it.
        activities = IslandRules.queued(activities, at: t0.addingTimeInterval(1.5))
        let battery = activities.first { $0.kind == .battery }
        #expect(battery?.start == t0.addingTimeInterval(7.5))
    }
}

struct SeveralTimersRulesTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func clocksAndRulerLabels() {
        #expect(TimerRules.clock(64 * 60 + 10) == "1:04:10")
        #expect(TimerRules.clock(25 * 60) == "25:00")
        #expect(TimerRules.bubbleLabel(90 * 60) == "1h")
        #expect(TimerRules.rulerLabel(minutes: 25) == "25")
        #expect(TimerRules.rulerLabel(minutes: 60) == "1h")
        #expect(TimerRules.rulerLabel(minutes: 90) == "1:30")
        #expect(TimerState(total: 64 * 60, endsAt: nil).lengthText == "1 h 4 min")
        #expect(TimerState(total: 120 * 60, endsAt: nil).lengthText == "2 h")
    }

    /// Your screenshot, 2026-09-30: the pointer sat half a tick left of 25. The ruler now rests on whole ticks only.
    @Test func theRulerRestsOnWholeTicks() {
        let near: CGFloat = TimerRules.rulerSnap(243, tickWidth: 10)
        let half: CGFloat = TimerRules.rulerSnap(245, tickWidth: 10)
        let past: CGFloat = TimerRules.rulerSnap(-7, tickWidth: 10)
        #expect(near == 240)   // tick 25's centre under the pointer
        #expect(half == 250)   // exactly between two ticks: the later one
        #expect(past == 0)     // before the first tick: the first
    }

    @Test func theNextEventIsTheEarliestAcrossTimers() {
        let long = TimerItem(kind: .focus, state: .start(length: 25 * 60, at: t0))
        let short = TimerItem(kind: .rest, state: .start(length: 3 * 60, at: t0))
        let next = TimerRules.nextEvent(in: [long, short], at: t0)
        #expect(next?.id == short.id)
        #expect(next?.milestone == 1)                              // "1 min left" at 2 min
        #expect(next?.at == t0.addingTimeInterval(2 * 60))
        #expect(TimerRules.nextEvent(in: [], at: t0) == nil)
    }
}

struct SideRulesTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func countdownsGoRightSoonestFirst() {
        let focus = UUID(), laundry = UUID(), paused = UUID()
        let timers: [(id: UUID, endsAt: Date?)] = [(focus, t0.addingTimeInterval(1500)), (laundry, t0.addingTimeInterval(3600)), (paused, nil)]
        // A class in 8 minutes beats both timers.
        let sides = SideRules.bubbles(keepAwake: true, timers: timers, soonEvent: (id: "class", start: t0.addingTimeInterval(480)),
                                      centreTimer: nil, now: t0)
        #expect(sides == SideBubbles(left: true, right: .event("class"), more: 3))
        // With no music the soonest timer is the pill itself, so it isn't repeated beside it.
        // Keep-awake off: the next countdown takes the left side, no "+1".
        let alone = SideRules.bubbles(keepAwake: false, timers: timers, soonEvent: nil, centreTimer: focus, now: t0)
        #expect(alone == SideBubbles(left: false, right: .timer(laundry), leftCountdown: .timer(paused), more: 0))
    }

    /// Your screenshot, 2026-11-16: music, a timer with a minute left and a meeting soon showed "1 +1" with the left
    /// side empty. Now the timer and the meeting both show; "+N" only past two.
    @Test func aSecondCountdownTakesTheLeftWhenKeepAwakeIsOff() {
        let timer = UUID(), laundry = UUID()
        let meeting = (id: "standup", start: t0.addingTimeInterval(300))
        let two = SideRules.bubbles(keepAwake: false, timers: [(timer, t0.addingTimeInterval(60))], soonEvent: meeting,
                                    centreTimer: nil, now: t0)
        #expect(two == SideBubbles(right: .timer(timer), leftCountdown: .event("standup"), more: 0))
        let three = SideRules.bubbles(keepAwake: false, timers: [(timer, t0.addingTimeInterval(60)), (laundry, t0.addingTimeInterval(900))],
                                      soonEvent: meeting, centreTimer: nil, now: t0)
        #expect(three == SideBubbles(right: .timer(timer), leftCountdown: .event("standup"), more: 1))
        // Keep-awake on: the coffee keeps the left; the meeting is "+1" as before.
        let coffee = SideRules.bubbles(keepAwake: true, timers: [(timer, t0.addingTimeInterval(60))], soonEvent: meeting,
                                       centreTimer: nil, now: t0)
        #expect(coffee == SideBubbles(left: true, right: .timer(timer), more: 1))
        // A swipe on the left hides the countdown there, and the pill brings it back.
        #expect(two.hiding([.left]) == SideBubbles(right: .timer(timer)))
        #expect(SideRules.afterSwipe(on: .left, available: two, hidden: []) == [.left])
        #expect(SideRules.afterSwipe(on: nil, available: two, hidden: [.left]) == [])
    }

    @Test func aClassOnlyCountsInItsLastTenMinutes() {
        let later = SideRules.bubbles(keepAwake: false, timers: [], soonEvent: (id: "class", start: t0.addingTimeInterval(1800)),
                                      centreTimer: nil, now: t0)
        #expect(later == .none)
        let started = SideRules.bubbles(keepAwake: false, timers: [], soonEvent: (id: "class", start: t0.addingTimeInterval(-60)),
                                        centreTimer: nil, now: t0)
        #expect(started == .none)
    }
}

/// Decision 11: what may interrupt while you focus.
struct FocusQuietTests {
    @Test func onlyCalendarTimesUpAndTheHUDGetThrough() {
        let through: [IslandActivity.Kind] = [.calendar, .timerDone, .hud(.volume), .hud(.brightness)]
        let skipped: [IslandActivity.Kind] = [.nowPlaying, .battery, .headphones, .timerNotice]
        for kind in through { #expect(kind.getsThroughFocus, "\(kind)") }
        for kind in skipped { #expect(!kind.getsThroughFocus, "\(kind)") }
    }
}

/// The HUD shows the output's icon, not its name (your pick, 2026-10-01).
struct OutputIconTests {
    @Test func eachOutputHasItsIcon() {
        #expect(AudioOutputKind.from(transport: "bltn", modelUID: "Speaker") == nil)              // built-in speakers
        #expect(AudioOutputKind.from(transport: "blue", modelUID: "ffffffff ffffffff") == .headphones)  // your earbuds
        #expect(AudioOutputKind.from(transport: "blue", modelUID: "200e 4c") == .airpodsPro)      // Apple's 0x200E
        #expect(AudioOutputKind.from(transport: "blue", modelUID: "200a 4c") == .airpodsMax)
        #expect(AudioOutputKind.from(transport: "airp", modelUID: nil) == .airplay)
        #expect(AudioOutputKind.from(transport: "hdmi", modelUID: nil) == .display)
        #expect(AudioOutputKind.from(transport: "usb ", modelUID: nil) == .external)
    }

    @Test func theHUDShowsTheIconUnlessMuted() {
        let earbuds = VolumeState(level: 0.6, isMuted: false, deviceName: "OnePlus Nord Buds", output: .headphones)
        #expect(earbuds.hudSymbol == "headphones")
        var muted = earbuds
        muted.isMuted = true
        #expect(muted.hudSymbol == "speaker.slash.fill")
        #expect(VolumeState(level: 0.6, isMuted: false).hudSymbol == "speaker.wave.2.fill")  // built-in: waves
    }
}

struct OpeningPageTests {
    /// Opening from a Live Activity in the pill lands on its tab (your report, 2026-10-02).
    @Test func liveActivitiesOpenTheirTab() {
        #expect(IslandRules.page(opening: .compact(.timer)) == .timers)
        #expect(IslandRules.page(opening: .compact(.timerNotice)) == .timers)
        #expect(IslandRules.page(opening: .compact(.timerDone)) == .timers)
        #expect(IslandRules.page(opening: .compact(.calendar)) == .calendar)
        #expect(IslandRules.page(opening: .compact(.keptMusic)) == nil)       // the usual: Music while music is loaded
        #expect(IslandRules.page(opening: .compact(.nowPlaying)) == nil)
        #expect(IslandRules.page(opening: .slim) == nil)                      // the slim bar has its own click (0.15)
    }
}


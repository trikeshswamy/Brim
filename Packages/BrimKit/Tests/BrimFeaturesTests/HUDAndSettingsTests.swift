import Foundation
import SwiftUI
import Testing
@testable import BrimCore
@testable import BrimFeatures

final class FakeVolumeService: VolumeService {
    let events: AsyncStream<VolumeEvent>
    private let continuation: AsyncStream<VolumeEvent>.Continuation
    var state: VolumeState? = VolumeState(level: 0.4375, isMuted: false)

    init() {
        (events, continuation) = AsyncStream.makeStream(of: VolumeEvent.self)
    }

    func start() {}
    func currentState() -> VolumeState? { state }
    func setLevel(_ level: Double) -> Bool { state?.level = level; return state != nil }
    func setMuted(_ muted: Bool) -> Bool { state?.isMuted = muted; return state != nil }
}

struct HUDStoreTests {
    private func makeStore() -> (HUDStore, IslandCoordinator) {
        let island = IslandCoordinator()
        return (HUDStore(volume: FakeVolumeService(), island: island), island)
    }

    @Test func baselineUpdatesQuietly() {
        let (store, island) = makeStore()
        store.handle(.baseline(VolumeState(level: 0.5, isMuted: false)))
        #expect(store.volume?.level == 0.5)
        #expect(island.surface == .hidden)   // no HUD at launch or when AirPods connect
        #expect(store.showing == nil)
    }

    @Test func realChangeShowsTheHUD() {
        let (store, island) = makeStore()
        store.handle(.baseline(VolumeState(level: 0.5, isMuted: false)))
        store.handle(.changed(VolumeState(level: 0.5625, isMuted: false)))
        #expect(island.surface == .compact(.hud(.volume)))
        #expect(store.showing == .volume)
    }

    @Test func brightnessKeyShowsTheBrightnessHUD() {
        let (store, island) = makeStore()
        store.brightnessChanged(to: 0.625)
        #expect(store.brightness == BrightnessState(level: 0.625))
        #expect(island.surface == .compact(.hud(.brightness)))
        #expect(store.showing == .brightness)
    }

    @Test func whileHoveringTheIslandStaysOpenAndShowsABanner() {
        let (store, island) = makeStore()
        island.hoverChanged(true)
        store.handle(.changed(VolumeState(level: 0.3, isMuted: false)))
        #expect(island.surface == .expanded(.calendar))
        #expect(store.showing == .volume)
    }
}

struct IslandSettingsTests {
    /// PRD F7 (2026-10-01): a new Mac isn't asked for Bluetooth at launch; AirPods notices start on only if it's allowed.
    @Test func airpodsNoticesStartOnOnlyIfBluetoothIsAllowed() throws {
        let suite = "IslandSettingsTests.airpods.\(UUID().uuidString)"
        let fresh = try #require(UserDefaults(suiteName: suite))
        #expect(IslandSettings(defaults: fresh).headphonesNotices == false)
        let allowed = try #require(UserDefaults(suiteName: suite + ".allowed"))
        #expect(IslandSettings(defaults: allowed, headphonesOnAtFirst: true).headphonesNotices)
        let settings = IslandSettings(defaults: fresh)
        settings.headphonesNotices = true                     // you turn them on
        #expect(IslandSettings(defaults: fresh).headphonesNotices)  // remembered
        fresh.removePersistentDomain(forName: suite)
        allowed.removePersistentDomain(forName: suite + ".allowed")
    }

    private func freshDefaults() -> UserDefaults {
        let name = testSuiteName("brim.tests")
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsMatchYourChoices() {
        let settings = IslandSettings(defaults: freshDefaults())
        #expect(settings.keepPillVisible)
        #expect(settings.openOnRest && settings.openOnPush && settings.openOnClick)
        #expect(settings.hudStyle == .standard)
        #expect(settings.enabledOpenTriggers == 3)
        #expect(settings.appearance == .liquidGlass)
        #expect(settings.keptStyle == .pill)  // "to begin with, keep the pill" (2026-09-29)
        #expect(settings.brimHUDOnly)          // "only Brim's HUD" (2026-09-29)
    }

    @Test func changesAreSavedAndReloaded() {
        let defaults = freshDefaults()
        let settings = IslandSettings(defaults: defaults)
        settings.keepPillVisible = false
        settings.openOnPush = false
        settings.hudStyle = .inline
        settings.appearance = .black
        #expect(settings.fullScreen == .hide)  // hidden over full-screen apps unless you pick the slim line
        settings.keptStyle = .slimLine
        settings.fullScreen = .slimLine
        let reloaded = IslandSettings(defaults: defaults)
        #expect(reloaded.fullScreen == .slimLine)
        #expect(reloaded.appearance == .black)
        #expect(reloaded.keptStyle == .slimLine)
        #expect(reloaded.keepPillVisible == false)
        #expect(reloaded.openOnPush == false)
        #expect(reloaded.hudStyle == .inline)
        #expect(reloaded.enabledOpenTriggers == 2)
    }
}

struct KeptPillTests {
    @Test func switchingToTheSlimLineAppliesImmediately() {
        let island = IslandCoordinator()
        island.setKeepPillVisible(true)
        island.setMedia(.playing)
        #expect(island.surface == .compact(.keptMusic))
        island.setKeptStyle(.slimLine)
        #expect(island.surface == .slim)
    }

    @Test func pausedPillHidesAfterAMinute() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let island = IslandCoordinator(now: { clock })
        island.setKeepPillVisible(true)
        island.setMedia(.playing)
        #expect(island.surface == .compact(.keptMusic))

        island.setMedia(.paused(since: clock))
        clock = clock.addingTimeInterval(59)
        island.reevaluate()
        #expect(island.surface == .compact(.keptMusic))  // short pause: still there

        clock = clock.addingTimeInterval(2)
        island.reevaluate()  // what the scheduled wake-up does at the 60 s mark
        #expect(island.surface == .hidden)
    }
}

/// Stands in for IOKit.
@MainActor
final class FakeBattery: BatteryService {
    let states: AsyncStream<BatteryState>
    private let continuation: AsyncStream<BatteryState>.Continuation
    init() { (states, continuation) = AsyncStream.makeStream(of: BatteryState.self) }
    func start() {}
}

struct BatteryStoreTests {
    private func reading(_ level: Double, _ power: BatteryState.Power) -> BatteryState {
        BatteryState(level: level, power: power, lowPowerMode: false)
    }

    private func makeStore() -> (BatteryStore, IslandCoordinator) {
        let island = IslandCoordinator()
        return (BatteryStore(service: FakeBattery(), island: island), island)
    }

    @Test func pluggingInShowsTheNoticeLaunchDoesNot() {
        let (store, island) = makeStore()
        store.handle(reading(0.62, .battery))
        #expect(island.surface == .hidden)                                  // first reading: quiet
        store.handle(reading(0.62, .charging))
        #expect(island.surface == .compact(.battery))
        #expect(store.notice == .pluggedIn(charging: true))
    }

    /// Your report (2026-10-03, 67%): macOS's flag lagged 3 s and more; below 80% plugging in means charging.
    @Test func belowEightyPercentPluggingInSaysChargingAtOnce() {
        let (store, island) = makeStore()
        store.handle(reading(0.67, .battery))
        store.handle(reading(0.67, .notCharging))                          // the flag hasn't caught up yet
        #expect(store.notice == .pluggedIn(charging: true))
        #expect(island.surface == .compact(.battery))
    }

    /// Your reports (83% and 89%): from 80% up it's "Plugged In", at once, never a wrong "Charging Paused".
    @Test func fromEightyPercentUpItSaysPluggedIn() {
        let (store, island) = makeStore()
        store.handle(reading(0.89, .battery))
        store.handle(reading(0.89, .notCharging))
        #expect(store.notice == .pluggedIn(charging: false))
        #expect(store.notice?.title == "Plugged In")
        #expect(island.surface == .compact(.battery))
    }

    @Test func unpluggingSaysNothing() {
        let (store, island) = makeStore()
        store.handle(reading(0.9, .notCharging))                           // at launch, plugged in: quiet
        store.handle(reading(0.9, .battery))                               // unplugged
        #expect(store.notice == nil)
        #expect(island.surface == .hidden)
    }

    @Test func switchedOffMeansNoNotices() {
        let island = IslandCoordinator()
        let store = BatteryStore(service: FakeBattery(), island: island)
        store.enabled = false
        store.handle(BatteryState(level: 0.62, power: .battery, lowPowerMode: false))
        store.handle(BatteryState(level: 0.62, power: .charging, lowPowerMode: false))
        #expect(island.surface == .hidden)
    }
}

struct HeadphonesNoticeTests {
    @Test func namesAndPartsFitTheNotice() {
        #expect(HeadphonesNoticeView.shortName("Sam’s AirPods Pro") == "AirPods Pro")
        let pods = HeadphonesBattery(name: "AirPods Pro", left: 100, right: 97, caseLevel: 88)
        #expect(HeadphonesNoticeView.parts(of: pods).map(\.label) == ["L", "R", "Case"])
        let caseAway = HeadphonesBattery(name: "AirPods Pro", left: 100, right: 97)
        #expect(HeadphonesNoticeView.parts(of: caseAway).map(\.level) == [100, 97, nil])  // "Case —"
        let max = HeadphonesBattery(name: "AirPods Max", single: 64)
        #expect(HeadphonesNoticeView.parts(of: max).map(\.level) == [64])
    }
}

final class FakeHeadphones: HeadphonesService {
    let connections: AsyncStream<HeadphonesConnection>
    var availability: Availability = .ready
    var permissionRequests = 0
    init() { (connections, _) = AsyncStream.makeStream(of: HeadphonesConnection.self) }
    func requestAccess() { permissionRequests += 1 }
    func start() {}
}

struct HeadphonesStoreTests {
    private let pods = HeadphonesBattery(name: "AirPods Pro", left: 100, right: 100, caseLevel: 88)

    @Test func connectingShowsTheNoticeButNotForOnesAlreadyConnected() {
        let island = IslandCoordinator()
        let store = HeadphonesStore(service: FakeHeadphones(), island: island)
        var seen: [Bool] = []
        store.onConnection = { _, shown in seen.append(shown) }
        store.handle(HeadphonesConnection(battery: pods, wasConnectedAtStart: true))
        #expect(island.surface == .hidden)
        store.handle(HeadphonesConnection(battery: pods))
        #expect(island.surface == .compact(.headphones))
        #expect(store.battery == pods)
        #expect(seen == [false, true])
    }

    @Test func disconnectingShowsBriefly() {
        var clock = Date()
        let island = IslandCoordinator(now: { clock })
        let store = HeadphonesStore(service: FakeHeadphones(), island: island)
        store.now = { clock }
        store.handle(HeadphonesConnection(battery: HeadphonesBattery(name: "AirPods Pro"), disconnected: true))
        #expect(island.surface == .compact(.headphones))
        #expect(store.disconnected)
        #expect(IslandActivity.headphones(at: .now, disconnected: true).duration == 1.5)
        clock += 31 * 60                                    // back after more than half an hour
        store.handle(HeadphonesConnection(battery: pods))
        #expect(!store.disconnected)
    }

    /// Your 3-day check (2026-10-05): earbuds re-announced themselves every 3–15 min, 93 notices in 1.5 days.
    @Test func reconnectingWithinHalfAnHourStaysQuiet() {
        var clock = Date()
        let island = IslandCoordinator(now: { clock })
        let store = HeadphonesStore(service: FakeHeadphones(), island: island)
        store.now = { clock }
        var seen: [Bool] = []
        store.onConnection = { _, shown in seen.append(shown) }
        let earbuds = HeadphonesBattery(name: "Earbuds")
        store.handle(HeadphonesConnection(battery: earbuds))               // shows
        clock += 10 * 60
        island.reevaluate()
        store.handle(HeadphonesConnection(battery: earbuds))               // again 10 min later: quiet
        #expect(island.surface == .hidden)
        store.handle(HeadphonesConnection(battery: pods))                  // another device: shows
        #expect(island.surface == .compact(.headphones))
        clock += 31 * 60
        island.reevaluate()
        store.handle(HeadphonesConnection(battery: earbuds))               // after half an hour: shows again
        #expect(seen == [true, false, true, true])
    }

    @Test func settingsShowsWhyItCantWork() {
        let service = FakeHeadphones()
        service.availability = .needsPermission
        let store = HeadphonesStore(service: service, island: IslandCoordinator())
        store.start()
        #expect(store.availability == .needsPermission)
        service.availability = .ready
        store.refreshAvailability()
        #expect(store.availability == .ready)
    }

    @Test func permissionIsRequestedOnlyByTheExplicitAction() {
        let service = FakeHeadphones()
        let store = HeadphonesStore(service: service, island: IslandCoordinator())
        store.start()
        #expect(service.permissionRequests == 0)
        store.requestPermission()
        #expect(service.permissionRequests == 1)
    }

    /// Feature 2: a Focus with "Notices: Important only" keeps headphones notices away, like a Brim Focus timer.
    @Test func aFocusWithImportantOnlyNoticesIsQuiet() {
        let island = IslandCoordinator()
        let store = HeadphonesStore(service: FakeHeadphones(), island: island)
        island.setFocusFilter(island: nil, importantOnly: true)
        store.handle(HeadphonesConnection(battery: pods))
        #expect(island.surface == .hidden)
        island.post(.calendar(at: .now))
        #expect(island.surface == .compact(.calendar))  // a class reminder still comes
        island.setFocusFilter(island: nil, importantOnly: false)
    }

    @Test func switchedOffInSettings() {
        let island = IslandCoordinator()
        let store = HeadphonesStore(service: FakeHeadphones(), island: island)
        store.enabled = false
        store.handle(HeadphonesConnection(battery: pods))
        #expect(island.surface == .hidden)
    }

    /// Your check (2026-10-01): earbuds without levels showed 10.5 s late. Now "Connected" shows at once and
    /// levels that come while it's up fill it in: the same notice, on its own 3 s.
    @Test func lateLevelsFillInTheNoticeWithoutASecondOne() {
        var now = Date()  // the store posts at the real time
        let island = IslandCoordinator(now: { now })
        let store = HeadphonesStore(service: FakeHeadphones(), island: island)
        var seen: [Bool] = []
        store.onConnection = { _, shown in seen.append(shown) }
        store.handle(HeadphonesConnection(battery: HeadphonesBattery(name: "AirPods Pro")))
        #expect(island.surface == .compact(.headphones))
        #expect(store.battery?.hasLevels == false)  // "Connected"
        now += 1.5
        store.handle(HeadphonesConnection(battery: pods, levelsLate: true))
        #expect(store.battery == pods)
        #expect(seen == [true])  // not a new connection
        now += 1.6  // 3.1 s after the first: the one notice ends on time, not 3 s after the levels
        island.reevaluate()
        #expect(island.surface == .hidden)
    }

    @Test func levelsAfterTheNoticeEndedAreDropped() {
        var now = Date()  // the store posts at the real time
        let island = IslandCoordinator(now: { now })
        let store = HeadphonesStore(service: FakeHeadphones(), island: island)
        store.handle(HeadphonesConnection(battery: HeadphonesBattery(name: "AirPods Pro")))
        now += 4
        island.reevaluate()
        store.handle(HeadphonesConnection(battery: pods, levelsLate: true))
        #expect(island.surface == .hidden)  // no notice brought back
        #expect(store.battery?.hasLevels == false)
    }
}

final class FakeCalendar: CalendarService {
    var availability: Availability = .ready
    var events: [CalendarEvent] = []
    var asked = 0
    let changes: AsyncStream<Void>
    init() { (changes, _) = AsyncStream.makeStream(of: Void.self) }
    func requestAccess() async -> Bool {
        asked += 1
        availability = .ready
        return true
    }
    func eventsToday() -> [CalendarEvent] { events }
    var calendarList: [CalendarSource] = []
    func calendars() -> [CalendarSource] { calendarList }
    func start() {}
}

/// Real time, starting from today's midday, so a test's "in 8 minutes" is always today. Brim's calendar counts only
/// today's events, and tests on the wall clock failed when run shortly before midnight (an event an hour ahead at 23:03
/// on 2026-09-30; 8 minutes ahead at 23:56 on 2026-10-05).
nonisolated struct MiddayClock: Sendable {
    private let midday = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
    private let started = Date()
    var now: Date { midday.addingTimeInterval(Date().timeIntervalSince(started)) }
}

/// A calendar store and its island on one clock, as in the app: the island drops a reminder by its own clock.
func calendarStore(_ service: FakeCalendar, clock: MiddayClock) -> (store: CalendarStore, island: IslandCoordinator) {
    let island = IslandCoordinator(now: { clock.now })
    let store = CalendarStore(service: service, island: island)
    store.now = { clock.now }
    return (store, island)
}

@Suite(.serialized)
struct CalendarStoreTests {
    /// 0.18.2: a calendar you switch off (Holidays) never shows or reminds you.
    @Test func aSwitchedOffCalendarNeverShows() async {
        let service = FakeCalendar()
        let clock = MiddayClock()
        let now = clock.now
        service.events = [
            CalendarEvent(id: "h", title: "Holiday", start: now.addingTimeInterval(1800), end: now.addingTimeInterval(3600), calendarID: "holidays"),
            CalendarEvent(id: "a", title: "Lecture", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(4200), calendarID: "work"),
        ]
        service.calendarList = [CalendarSource(id: "holidays", title: "Holidays", account: "Other", color: .fallback)]
        let (store, _) = calendarStore(service, clock: clock)
        store.start()
        await store.setEnabled(true)
        #expect(store.next?.id == "h")
        #expect(store.calendars.map(\.id) == ["holidays"])
        store.hiddenCalendars = ["holidays"]
        #expect(store.next?.id == "a")
        #expect(store.agenda.map(\.id) == ["a"])
    }

    @Test func showsTheNextEventOnlyWhenOn() async {
        let service = FakeCalendar()
        let clock = MiddayClock()
        let now = clock.now
        service.events = [CalendarEvent(id: "a", title: "Lecture", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(4200))]
        let (store, _) = calendarStore(service, clock: clock)
        store.start()
        #expect(store.next == nil)  // off until Settings turns it on
        await store.setEnabled(true)
        #expect(store.next?.id == "a")
        await store.setEnabled(false)
        #expect(store.next == nil)
    }

    @Test func enablingDoesNotAskForAccess() async {
        let service = FakeCalendar()
        service.availability = .starting
        let store = CalendarStore(service: service, island: IslandCoordinator())
        await store.setEnabled(true)
        await store.setEnabled(true)
        #expect(service.asked == 0)
        #expect(store.availability == .starting)
        await store.requestPermission()
        #expect(service.asked == 1)
        #expect(store.availability == .ready)
    }

    @Test func theReminderShowsOnTime() async throws {
        let service = FakeCalendar()
        let clock = MiddayClock()
        let start = clock.now.addingTimeInterval(CalendarRules.reminderLead + 0.3)  // reminder due in 0.3 s
        service.events = [CalendarEvent(id: "a", title: "Lecture", start: start, end: start.addingTimeInterval(3600))]
        let (store, island) = calendarStore(service, clock: clock)
        var late: TimeInterval?
        store.onReminder = { late = $0 }
        store.start()
        await store.setEnabled(true)
        for _ in 0..<60 where late == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(island.surface == .compact(.calendar))
        #expect(store.reminding?.id == "a")
        #expect((late ?? 99) < 1)  // release goal: within 1 s
    }

    @Test func remindersCanBeSwitchedOff() async throws {
        let service = FakeCalendar()
        let clock = MiddayClock()
        let start = clock.now.addingTimeInterval(CalendarRules.reminderLead + 0.2)
        service.events = [CalendarEvent(id: "a", title: "Lecture", start: start, end: start.addingTimeInterval(3600))]
        let (store, island) = calendarStore(service, clock: clock)
        store.remindersEnabled = false
        store.start()
        await store.setEnabled(true)
        try await Task.sleep(for: .milliseconds(500))
        #expect(island.surface == .hidden)
        #expect(store.next?.id == "a")  // still shown in the open island
    }
}

final class FakeAlarm: TimerAlarm {
    var prepared = 0
    var rang: [String] = []
    var silenced = 0
    func prepare() { prepared += 1 }
    func ring(title: String, body: String) { rang.append(body) }
    func silence() { silenced += 1 }
}

@Suite(.serialized)
struct TimerStoreTests {
    private func freshDefaults() -> UserDefaults {
        let name = testSuiteName("brim.tests")
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aRunningTimerShowsAndASwipeKeepsIt() {
        let island = IslandCoordinator()
        let alarm = FakeAlarm()
        let timer = TimerStore(island: island, alarm: alarm, defaults: freshDefaults())
        #expect(!island.swipe(on: nil, available: .none))  // nothing resting: no haptic
        timer.start(minutes: 25)
        #expect(alarm.prepared == 1)
        #expect(island.surface == .compact(.timer))  // shown by default (2026-09-30)
        #expect(!island.swipe(on: nil, available: .none))  // one timer is the pill itself: no bubbles to hide
        #expect(island.surface == .compact(.timer))  // the pill never hides by swipe (decision 9)
    }

    @Test func theEndRingsAndStopEndsIt() async throws {
        let island = IslandCoordinator()
        let alarm = FakeAlarm()
        let timer = TimerStore(island: island, alarm: alarm, defaults: freshDefaults())
        var late: TimeInterval?
        timer.onEnd = { late = $0 }
        timer.start(length: 0.3)
        for _ in 0..<60 where late == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(island.surface == .compact(.timerDone))
        #expect(alarm.rang == ["Your 0 s timer is done."] || alarm.rang.count == 1)
        #expect((late ?? 99) < 1)  // release goal: within 1 s
        timer.stopAlarm()
        #expect(island.surface == .hidden)
        #expect(timer.state == nil)
    }

    @Test func survivesARelaunch() {
        let island = IslandCoordinator()
        let defaults = freshDefaults()
        let t0 = Date()
        let first = TimerStore(island: island, alarm: FakeAlarm(), defaults: defaults)
        first.now = { t0 }
        first.start(minutes: 25)
        let again = TimerStore(island: island, alarm: FakeAlarm(), defaults: defaults)
        again.now = { t0.addingTimeInterval(60) }
        again.start()
        let left = again.state?.remaining(at: t0.addingTimeInterval(60)) ?? 0
        #expect(abs(left - 24 * 60) < 0.001)  // saved as JSON: sub-microsecond rounding
        #expect(island.surface == .compact(.timer))
    }

    @Test func theEndGoesStraightToTimesUp() {
        // The island must never pass through "hidden" between the timer pill and "Time's up".
        let island = IslandCoordinator()
        let defaults = freshDefaults()
        let t0 = Date()
        let first = TimerStore(island: island, alarm: FakeAlarm(), defaults: defaults)
        first.now = { t0 }
        first.start(minutes: 5)
        #expect(island.surface == .compact(.timer))
        var seen: [IslandSurface] = []
        island.onSurfaceChange = { seen.append($0) }
        let again = TimerStore(island: island, alarm: FakeAlarm(), defaults: defaults)
        again.now = { t0.addingTimeInterval(301) }
        again.start()
        #expect(seen == [.compact(.timerDone)])  // one change: timer pill → Time's up
    }

    @Test func endedWhileAwaySaysWhen() {
        let island = IslandCoordinator()
        let defaults = freshDefaults()
        let t0 = Date()
        let first = TimerStore(island: island, alarm: FakeAlarm(), defaults: defaults)
        first.now = { t0 }
        first.start(minutes: 5)
        // The Mac sleeps (or Brim quits) and comes back 10 minutes later.
        let alarm = FakeAlarm()
        let again = TimerStore(island: island, alarm: alarm, defaults: defaults)
        again.now = { t0.addingTimeInterval(600) }
        again.start()
        #expect(again.state == nil)
        #expect(again.ended?.whileAway == true)
        #expect(alarm.rang.first?.contains("ended at") == true)
        #expect(island.surface == .compact(.timerDone))
    }

    @Test func swipesAreSidewaysAndDeliberate() {
        #expect(SwipeRules.isSideways(dx: 120, dy: 10))
        #expect(SwipeRules.isSideways(dx: -90, dy: 20))   // either direction
        #expect(!SwipeRules.isSideways(dx: 15, dy: 0))    // a brush
        #expect(!SwipeRules.isSideways(dx: 80, dy: 60))   // diagonal: probably scrolling
    }
}

/// Decision 9 (your fix round, 2026-09-30): the swipe hides only the side bubbles (Live Activities); the pill stays.
struct BubbleSwipeTests {
    private func musicResting() -> IslandCoordinator {
        let island = IslandCoordinator()
        island.setKeepPillVisible(true)
        island.setMedia(.playing)
        return island
    }

    private let both = SideBubbles(left: true, right: .timer(UUID()))

    /// Your example: a timer and keep-awake; swipe on the timer, only the timer hides.
    @Test func aSwipeOnTheTimerHidesOnlyTheTimer() {
        let island = musicResting()
        island.setTimerRunning(true)
        #expect(island.swipe(on: .right, available: both))
        #expect(island.hiddenBubbles == [.right])          // keep-awake stays
        #expect(island.surface == .compact(.keptMusic))    // the pill stays
        #expect(island.swipe(on: nil, available: both))    // swipe the pill: it's back
        #expect(!island.bubblesHidden)
        #expect(island.swipe(on: nil, available: both))    // and again: both hide together (your pick, 2026-10-01)
        #expect(island.hiddenBubbles == [.left, .right])
        #expect(island.surface == .compact(.keptMusic))    // the pill stays
    }

    @Test func nothingToHideMeansNoTick() {
        let island = musicResting()
        #expect(!island.swipe(on: nil, available: .none))
        #expect(!island.swipe(on: .left, available: .none))
        #expect(!island.bubblesHidden)
    }

    @Test func notOnAGlanceOrTheOpenIsland() {
        let island = musicResting()
        island.post(.nowPlaying(at: .now))                  // a song-change glance
        #expect(!island.swipe(on: .right, available: both))
        island.hoverChanged(true)                           // open: a sideways swipe may be scrolling the ruler
        #expect(!island.swipe(on: .right, available: both))
        #expect(!island.bubblesHidden)
    }

    @Test func somethingNewBringsBackOnlyItsSide() {
        let island = musicResting()
        island.hideBubbles()                                // right-click → Hide Live Activities: both
        island.hoverChanged(true)                           // opening the island doesn't change it
        island.hoverChanged(false)
        #expect(island.hiddenBubbles == [.left, .right])
        island.showBubbles([.right])                        // a new timer
        #expect(island.hiddenBubbles == [.left])            // keep-awake stays hidden
        island.showBubbles()                                // Show Live Activities
        #expect(!island.bubblesHidden)
    }

    @Test func hiddenBubblesDrawNothingOnTheirSide() {
        #expect(IslandSides.current(surface: .compact(.keptMusic), timer: nil, calendar: nil, keepAwake: true).left)
        #expect(IslandSides.current(surface: .compact(.keptMusic), timer: nil, calendar: nil, keepAwake: true,
                                    hiding: [.left]) == .none)
    }
}

struct PageSwitchTests {
    @Test func theChoiceLastsWhileOpen() {
        var clock = Date()
        let island = IslandCoordinator(now: { clock })
        island.setMedia(.playing)
        island.hoverChanged(true)
        #expect(island.surface == .expanded(.music))
        island.showPage(.calendar)
        #expect(island.surface == .expanded(.calendar))
        island.hoverChanged(false)
        clock = clock.addingTimeInterval(1)  // past the 0.6 s grace: the island closes
        island.reevaluate()
        #expect(!island.surface.isExpanded)
        island.hoverChanged(true)
        #expect(island.surface == .expanded(.music))  // opens on Now Playing again
    }

    /// Your report (2026-10-02): with music paused a while, the running timer is the pill, and clicking it opened Music.
    @Test func theTimerPillOpensTimers() {
        let island = IslandCoordinator()
        island.setMedia(.paused(since: .distantPast))  // paused over a minute ago: the music pill has stepped away
        island.setTimerRunning(true)
        #expect(island.surface == .compact(.timer))
        island.hoverChanged(true)
        #expect(island.surface == .expanded(.timers))
    }

    @Test func aTimerNoticeAndAClassReminderOpenTheirTabs() {
        let notice = IslandCoordinator()
        notice.setMedia(.playing)
        notice.post(.timerNotice(at: .now))           // "5 min left" over the music pill
        notice.hoverChanged(true)
        #expect(notice.surface == .expanded(.timers))

        let reminder = IslandCoordinator()
        reminder.setMedia(.playing)
        reminder.post(.calendar(at: .now))            // "Class · in 5 min"
        reminder.hoverChanged(true)
        #expect(reminder.surface == .expanded(.calendar))
    }

    /// Your report (2026-10-02): in a full-screen video even the slim line drew the eye. Only what matters shows.
    @Test func aFullScreenVideoOnlyGetsImportantNotices() {
        let island = IslandCoordinator()
        island.setKeepPillVisible(true)
        island.setMedia(.playing)
        island.setFrontIsFullScreen(true)
        #expect(island.surface == .hidden)
        island.post(.nowPlaying(at: .now))                // music resuming: skipped
        island.post(.battery(at: .now))                   // plugging in: skipped
        island.post(.timerNotice(at: .now))               // "5 min left": skipped (the timer still ends on time)
        #expect(island.surface == .hidden)
        island.post(.hud(.volume, at: .now))              // you pressed a key: shown
        #expect(island.surface == .compact(.hud(.volume)))
        island.dismiss(.hud(.volume))
        island.post(.calendar(at: .now))                  // a class in 5 minutes: shown
        #expect(island.surface == .compact(.calendar))
        island.dismiss(.calendar)
        island.setFrontIsFullScreen(false)
        #expect(island.surface == .compact(.keptMusic))   // back as usual when you leave full screen
    }

    @Test func theMusicPillStillOpensMusic() {
        let island = IslandCoordinator()
        island.setKeepPillVisible(true)               // Brim's default
        island.setMedia(.playing)
        island.setTimerRunning(true)                  // the timer rides beside it as a bubble (that opens Timers)
        #expect(island.surface == .compact(.keptMusic))
        island.hoverChanged(true)
        #expect(island.surface == .expanded(.music))
    }
}

struct GlanceBannerTests {
    @Test func aGlanceWhileOpenBecomesTheBanner() {
        let island = IslandCoordinator()
        island.setMedia(.playing)
        island.hoverChanged(true)
        island.post(.battery(at: .now))
        #expect(island.surface == .expanded(.music))  // the island stays open
        #expect(island.banner == .battery)
        island.post(.nowPlaying(at: .now))
        #expect(island.banner == .battery)  // a song change needs no banner
        island.hoverChanged(false)
    }
}

@Suite(.serialized)
struct SeveralTimersTests {
    private func freshDefaults() -> UserDefaults {
        let name = testSuiteName("brim.tests")
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func theSoonestLeadsAndFiveIsTheLimit() {
        let island = IslandCoordinator()
        let timer = TimerStore(island: island, alarm: FakeAlarm(), defaults: freshDefaults())
        let t0 = Date()
        timer.now = { t0 }
        timer.start(minutes: 25)
        timer.start(length: 5 * 60, kind: .rest)
        timer.start(minutes: 60)
        #expect(timer.items.count == 3)
        #expect(timer.soonest?.kind == .rest)            // the ring shows the one that ends first
        timer.pause(timer.soonest!.id)
        let leading: TimeInterval = timer.soonest?.state.total ?? 0
        #expect(leading == 1500)  // paused ones step aside: the 25-minute Focus leads
        timer.start(minutes: 5)
        timer.start(minutes: 5)
        #expect(!timer.canStartAnother)
        timer.start(minutes: 5)
        #expect(timer.items.count == 5)                  // five at most
        timer.cancel(timer.items[0].id)
        #expect(timer.items.count == 4)
    }

    @Test func aFocusTimerOffersABreak() {
        let island = IslandCoordinator()
        let alarm = FakeAlarm()
        let defaults = freshDefaults()
        let t0 = Date()
        let first = TimerStore(island: island, alarm: FakeAlarm(), defaults: defaults)
        first.now = { t0 }
        first.start(minutes: 25)
        let again = TimerStore(island: island, alarm: alarm, defaults: defaults)
        again.now = { t0.addingTimeInterval(25 * 60 + 1) }
        again.start()
        #expect(again.ended?.kind == .focus)
        #expect(alarm.rang.first?.contains("Focus timer") == true)
        again.startBreak()
        #expect(again.items.map(\.kind) == [.rest])
        let breakLength: TimeInterval = again.items.first?.state.total ?? 0
        #expect(breakLength == 300)
        #expect(island.surface == .compact(.timer))  // the break runs; Time's up is gone
    }

    /// The 7-day run's counts (your pick, 2026-10-01): what you did, numbers only.
    @Test func usageCountsWhatYouDo() {
        _ = Usage.take()
        let island = IslandCoordinator()
        let timer = TimerStore(island: island, alarm: FakeAlarm(), defaults: freshDefaults())
        timer.start(minutes: 25)
        island.post(.battery(at: .now))                    // quieted: you're focusing
        let counts = Usage.take()
        #expect((counts["timer.start.focus"] ?? 0) >= 1)
        #expect((counts["glance.quieted.battery"] ?? 0) >= 1)
        #expect(Usage.take()["timer.start.focus"] == nil)  // taken, so the next health line starts afresh
    }

    /// Your pick (2026-10-01): when a Break ends, Time's up offers Focus, one click back to work.
    @Test func aBreakOffersFocus() {
        let island = IslandCoordinator()
        let defaults = freshDefaults()
        let t0 = Date()
        let first = TimerStore(island: island, alarm: FakeAlarm(), defaults: defaults)
        first.now = { t0 }
        first.start(length: 300, kind: .rest)
        let again = TimerStore(island: island, alarm: FakeAlarm(), defaults: defaults)
        again.now = { t0.addingTimeInterval(301) }
        again.start()
        #expect(again.ended?.kind == .rest)
        again.startNext()
        #expect(again.items.map(\.kind) == [.focus])
        let focusLength: TimeInterval = again.items.first?.state.total ?? 0
        #expect(focusLength == 1500)
        #expect(island.surface == .compact(.timer))  // focusing; Time's up is gone
    }

    /// Decision 11 (your pick, 2026-10-01): while a Focus timer runs, only a calendar reminder and Time's up interrupt.
    @Test func focusMeansQuiet() {
        let island = IslandCoordinator()
        let timer = TimerStore(island: island, alarm: FakeAlarm(), defaults: freshDefaults())
        timer.start(minutes: 25)
        #expect(island.surface == .compact(.timer))
        island.post(.battery(at: .now))
        #expect(island.surface == .compact(.timer))      // skipped while you focus
        island.post(.calendar(at: .now))
        #expect(island.surface == .compact(.calendar))   // a class or meeting still gets through
    }

    @Test func aPausedFocusOrABreakIsntQuiet() {
        let island = IslandCoordinator()
        let timer = TimerStore(island: island, alarm: FakeAlarm(), defaults: freshDefaults())
        timer.start(minutes: 25)
        timer.pause(timer.items[0].id)
        island.post(.battery(at: .now))
        #expect(island.surface == .compact(.battery))
        let breakOnly = IslandCoordinator()
        let rest = TimerStore(island: breakOnly, alarm: FakeAlarm(), defaults: freshDefaults())
        rest.start(length: 300, kind: .rest)
        breakOnly.post(.battery(at: .now))
        #expect(breakOnly.surface == .compact(.battery))
    }

    @Test func switchingModesMovesTheRuler() {
        let timer = TimerStore(island: IslandCoordinator(), alarm: FakeAlarm(), defaults: freshDefaults())
        #expect(timer.pickedMinutes == 25)
        timer.mode = .rest
        #expect(timer.pickedMinutes == 5)
        timer.pickedMinutes = 12
        timer.startPicked()
        let picked: TimeInterval = timer.items.first?.state.total ?? 0
        #expect(timer.items.first?.kind == .rest && picked == 720)
    }

    @Test func aTimerFromBrim012CarriesOver() throws {
        let defaults = freshDefaults()
        let t0 = Date()
        let old = TimerState.start(length: 25 * 60, at: t0)
        defaults.set(try JSONEncoder().encode(old), forKey: "timer.state")
        let timer = TimerStore(island: IslandCoordinator(), alarm: FakeAlarm(), defaults: defaults)
        timer.now = { t0.addingTimeInterval(60) }
        timer.start()
        #expect(timer.items.count == 1)
        #expect(defaults.data(forKey: "timer.state") == nil)
    }
}

struct ClassCountdownTests {
    @Test func aClassWithinTenMinutesIsSoon() async {
        let service = FakeCalendar()
        let clock = MiddayClock()
        let now = clock.now
        service.events = [CalendarEvent(id: "a", title: "Lecture", start: now.addingTimeInterval(8 * 60), end: now.addingTimeInterval(68 * 60))]
        let (store, _) = calendarStore(service, clock: clock)
        store.remindersEnabled = false
        await store.setEnabled(true)
        #expect(store.soon?.id == "a")
        service.events = [CalendarEvent(id: "b", title: "Lab", start: now.addingTimeInterval(30 * 60), end: now.addingTimeInterval(90 * 60))]
        store.refresh()
        #expect(store.soon == nil)  // 30 minutes away: not yet
    }
}

final class FakeKeepAwake: KeepAwakeService {
    var awake = false
    var refuse = false
    func setAwake(_ on: Bool) -> Bool {
        if on && refuse { return false }
        awake = on
        return true
    }
}

struct KeepAwakeTests {
    @Test func untilIStopItHoldsTheMacAwakeAndShowsTheCoffee() {
        let island = IslandCoordinator()
        let service = FakeKeepAwake()
        let store = KeepAwakeStore(service: service, island: island)
        store.start(minutes: nil)
        #expect(store.isOn && service.awake)
        #expect(store.period == nil)                     // no length: no ring
        #expect(store.status == "Keeping your Mac awake until you stop it")
        #expect(island.surface == .compact(.keepAwake))  // alone: the small coffee pill
        island.setKeepPillVisible(true)
        island.setMedia(.playing)
        #expect(island.surface == .compact(.keptMusic))  // with music: the coffee rides on the pill's left
        store.stop()
        #expect(!store.isOn && !service.awake)
    }

    @Test func aLengthTurnsItselfOff() async {
        let island = IslandCoordinator()
        let service = FakeKeepAwake()
        let store = KeepAwakeStore(service: service, island: island)
        store.start(length: 0.2)
        #expect(store.isOn && store.period != nil)
        #expect(store.status.hasPrefix("Keeping your Mac awake until "))
        for _ in 0..<50 where store.isOn { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(!store.isOn && !service.awake)
        #expect(store.period == nil)
        #expect(island.surface == .hidden)               // the coffee pill goes with it
    }

    @Test func choosingAgainStartsOverFromNow() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let store = KeepAwakeStore(service: FakeKeepAwake(), island: IslandCoordinator())
        store.now = { clock }
        store.start(minutes: 10)
        clock = clock.addingTimeInterval(5 * 60)
        store.start(minutes: 30)
        let until: Date? = store.period?.until
        #expect(until == clock.addingTimeInterval(30 * 60))
        store.start(minutes: nil)                        // "Until I stop it" drops the length
        #expect(store.isOn && store.period == nil)
        store.stop()
    }

    @Test func aStoppedLengthNeverEndsALaterOne() async {
        let store = KeepAwakeStore(service: FakeKeepAwake(), island: IslandCoordinator())
        store.start(length: 0.1)
        store.stop()
        store.start(minutes: nil)
        try? await Task.sleep(for: .milliseconds(300))   // past the first length's end
        #expect(store.isOn)
        store.stop()
    }

    @Test func aRefusedAssertionStaysOff() {
        let service = FakeKeepAwake()
        service.refuse = true
        let store = KeepAwakeStore(service: service, island: IslandCoordinator())
        store.set(true)
        #expect(!store.isOn)  // never claim the Mac is kept awake when macOS said no
        store.start(minutes: 10)
        #expect(!store.isOn && store.period == nil)
    }

    @Test func theMenuSaysYourWords() {
        #expect(KeepAwakeRules.choices.map(KeepAwakeRules.label(minutes:)) ==
                ["10 min", "30 min", "1 hour", "2 hours", "Until I stop it"])
    }

    @Test func theRingDrains() {
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(600)
        #expect(KeepAwakeRules.share(since: start, until: end, at: start) == 1)
        #expect(KeepAwakeRules.share(since: start, until: end, at: start.addingTimeInterval(150)) == 0.75)
        #expect(KeepAwakeRules.share(since: start, until: end, at: end.addingTimeInterval(5)) == 0)
    }
}

/// Your note, 2026-09-30: in Black a swiped bubble "doesn't go in fully in one smooth motion, it pauses, then hides".
/// Renders a bubble-sized disc along the way back in, masked like the real layer, and counts what still shows.
@MainActor
struct BubbleTuckTests {
    static func visiblePixels(_ appearance: IslandAppearance, progress: CGFloat, shrinks: Bool) -> Int {
        let ring = IslandMetrics.timerBubble(appearance: appearance)
        let pill = IslandMetrics.pillSize(appearance: appearance)
        let tucked = pill.width / 2 - ring.side / 2
        let lift = shrinks ? SideBubblesLayer.tuckLift(appearance: appearance) : 0
        let view = ZStack(alignment: .top) {
            Circle().fill(Color.orange)
                .frame(width: ring.side, height: ring.side)
                .padding(.top, ring.top)
                .modifier(PullOutEffect(progress: progress, tucked: tucked, settled: ring.centreOffset, shrinks: shrinks, lift: lift))
        }
        .frame(width: IslandMetrics.panelSize.width, height: 60, alignment: .top)
        .mask { SideBubblesLayer.outsideThePill(pill, appearance: appearance) }
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return -1 }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 12 }.count
    }

    @Test func theOldWayLeftACrescentAtTheNotchCorner() {
        #expect(Self.visiblePixels(.black, progress: 0, shrinks: false) > 20)   // what you saw linger
    }

    @Test func nowNothingShowsOnceItsIn() {
        for look in IslandAppearance.allCases {
            #expect(Self.visiblePixels(look, progress: 0, shrinks: true) == 0)
        }
    }

    /// The real layer at rest, through its real transition: the bubble sits once beside the pill. In 0.13.3 two stacked
    /// transitions moved it twice as far out (beyond the island's edge in Black, so you saw nothing; your test, 10-01).
    /// Black only: Liquid Glass draws nothing offscreen. `--island-bench` checks both looks on screen.
    @Test func aRestingBubbleSitsBesideThePill() throws {
        for look in [IslandAppearance.black] {
            let layer = SideBubblesLayer(sides: SideBubbles(left: true), appearance: look, timer: nil, calendar: nil)
                .frame(width: IslandMetrics.panelSize.width, height: 60, alignment: .top)
            let renderer = ImageRenderer(content: layer)
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            let width = image.width, height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                                 bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let seen = (0..<width * height).filter { pixels[$0 * 4 + 3] > 12 }.map { CGFloat($0 % width) }
            try #require(!seen.isEmpty, "\(look): nothing drawn")
            let centre = seen.reduce(0, +) / CGFloat(seen.count)
            let expected = IslandMetrics.panelSize.width / 2 - IslandMetrics.timerBubble(appearance: look).centreOffset
            #expect(abs(centre - expected) < 2, "\(look): bubble at \(centre), expected \(expected)")
        }
    }

    @Test func theWayInNeverPauses() {
        for look in IslandAppearance.allCases {
            let seen = [1, 0.8, 0.6, 0.4, 0.2, 0.1, 0].map { Self.visiblePixels(look, progress: $0, shrinks: true) }
            for (earlier, later) in zip(seen, seen.dropFirst()) {
                #expect(later <= earlier)   // less and less shows, all the way in
            }
        }
    }
}

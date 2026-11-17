import Foundation
import Testing
@testable import BrimFeatures

/// The first-launch welcome, round 3: shown once, three steps, pointing at the top moves Hello on, a permission only
/// when you flip its switch, the one restart waits for Done, launch at login saved only when it changed.
@MainActor
struct WelcomeFlowTests {
    /// Records what the switches did instead of asking macOS.
    private final class Fake {
        var calendarOn = false
        /// What macOS answers to the calendar prompt.
        var calendarAllowed = true
        var airPodsOn = false
        var volumeOn = false
        /// Allowed in System Settings (the fake's stand-in for AXIsProcessTrusted).
        var volumeAllowed = false
        /// Allowed during the welcome, not yet applied: Brim must restart.
        var volumeApplied = false
        var loginOn = false
        var asked: [String] = []
        var loginSet: [Bool] = []

        var actions: WelcomeFlow.Actions {
            WelcomeFlow.Actions(
                turnOnCalendar: { [self] in asked.append("calendar"); calendarOn = calendarAllowed },
                turnOffCalendar: { [self] in calendarOn = false },
                calendarIsOn: { [self] in calendarOn },
                turnOnAirPods: { [self] in asked.append("bluetooth"); airPodsOn = true },
                turnOffAirPods: { [self] in airPodsOn = false },
                airPodsAreOn: { [self] in airPodsOn },
                turnOnVolume: { [self] in volumeOn = true; if !volumeAllowed { asked.append("accessibility") } },
                turnOffVolume: { [self] in volumeOn = false },
                volumeIsOn: { [self] in volumeOn && volumeAllowed },
                volumeNeedsRestart: { [self] in volumeOn && volumeAllowed && !volumeApplied },
                restart: { [self] in asked.append("restart") },
                launchAtLoginIsOn: { [self] in loginOn },
                setLaunchAtLogin: { [self] on in loginSet.append(on); loginOn = on })
        }
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: testSuiteName("brim.welcome"))!
    }

    private func flow(_ fake: Fake, _ store: UserDefaults? = nil) -> WelcomeFlow {
        WelcomeFlow(actions: fake.actions, defaults: store ?? defaults(), resultPause: .zero)
    }

    @Test func showsOnceAndSkipAsksNothing() {
        let fake = Fake(), store = defaults()
        var shown: [Bool] = []
        let welcome = flow(fake, store)
        welcome.onShowingChange = { shown.append($0) }
        welcome.startIfNeeded()
        #expect(welcome.isShowing && welcome.step == .hello)
        welcome.skip()
        #expect(!welcome.isShowing && shown == [true, false])
        #expect(fake.asked.isEmpty)
        let again = flow(fake, store)
        again.startIfNeeded()
        #expect(!again.isShowing)
    }

    @Test func threeStepsWithNothingFlippedAskNothing() {
        let fake = Fake()
        let welcome = flow(fake)
        welcome.startIfNeeded()
        #expect(WelcomeFlow.Step.allCases.count == 3)
        welcome.next()
        #expect(welcome.step == .look)
        welcome.next()
        #expect(welcome.step == .ready)
        #expect(welcome.calendar == .off && !welcome.airPods && welcome.volume == .off)
        welcome.next()  // Done
        #expect(!welcome.isShowing && fake.asked.isEmpty)
    }

    @Test func pointingAtTheTopMovesHelloOn() async {
        let welcome = flow(Fake())
        welcome.startIfNeeded()
        await welcome.pointedAtTop()
        #expect(welcome.step == .look && welcome.outcome == nil)
        await welcome.pointedAtTop()  // only on Hello
        #expect(welcome.step == .look)
    }

    @Test func calendarAsksOnlyWhenFlipped() async {
        let fake = Fake()
        let welcome = flow(fake)
        welcome.startIfNeeded()
        welcome.next(); welcome.next()
        await welcome.setCalendar(true)
        #expect(fake.asked == ["calendar"] && welcome.calendar == .on)
        await welcome.setCalendar(false)
        #expect(welcome.calendar == .off && !fake.calendarOn)
    }

    @Test func calendarRefusedSaysSo() async {
        let fake = Fake()
        fake.calendarAllowed = false
        let welcome = flow(fake)
        welcome.startIfNeeded()
        welcome.next(); welcome.next()
        await welcome.setCalendar(true)
        #expect(welcome.calendar == .notAllowed)
        await welcome.setCalendar(false)
        #expect(welcome.calendar == .off)
    }

    @Test func airPodsSwitch() {
        let fake = Fake()
        let welcome = flow(fake)
        welcome.startIfNeeded()
        welcome.setAirPods(true)
        #expect(welcome.airPods && fake.asked == ["bluetooth"])
        welcome.setAirPods(false)
        #expect(!welcome.airPods)
    }

    /// Volume waits for System Settings, then Done restarts once.
    @Test func volumeWaitsThenDoneRestarts() {
        let fake = Fake()
        let welcome = flow(fake)
        welcome.startIfNeeded()
        welcome.next(); welcome.next()
        welcome.setVolume(true)
        #expect(welcome.volume == .waiting && fake.asked == ["accessibility"])
        fake.volumeAllowed = true  // you allowed Brim in System Settings
        welcome.refresh()
        #expect(welcome.volume == .on && welcome.restartPending)
        welcome.done()
        #expect(fake.asked == ["accessibility", "restart"])
    }

    @Test func volumeOffWhileWaitingIsOff() {
        let fake = Fake()
        let welcome = flow(fake)
        welcome.startIfNeeded()
        welcome.setVolume(true)
        welcome.setVolume(false)
        #expect(welcome.volume == .off && !welcome.restartPending)
        welcome.done()
        #expect(!fake.asked.contains("restart"))
    }

    @Test func alreadyOnShowsOn() {
        let fake = Fake()
        fake.calendarOn = true; fake.airPodsOn = true; fake.volumeOn = true; fake.volumeAllowed = true
        fake.volumeApplied = true
        let welcome = flow(fake)
        welcome.showAgain()
        #expect(welcome.calendar == .on && welcome.airPods && welcome.volume == .on && !welcome.restartPending)
    }

    @Test func launchAtLoginSavedOnlyWhenChanged() {
        let fake = Fake()
        let first = flow(fake)
        first.startIfNeeded()
        #expect(first.launchAtLogin)  // a first launch suggests it
        first.done()
        #expect(fake.loginSet == [true])
        let again = flow(fake)
        again.showAgain()
        #expect(again.launchAtLogin)  // as it is now
        again.done()
        #expect(fake.loginSet == [true])
    }

    /// Done hands off (the dimmed screen with the arrow); Skip doesn't; after Finish & Restart it waits for the relaunch.
    @Test func doneHandsOffSkipDoesNot() {
        let fake = Fake()
        var handOffs = 0
        let skipped = flow(fake)
        skipped.onHandOff = { handOffs += 1 }
        skipped.startIfNeeded()
        skipped.skip()
        #expect(handOffs == 0)
        let finished = flow(fake)
        finished.onHandOff = { handOffs += 1 }
        finished.startIfNeeded()
        finished.done()
        #expect(handOffs == 1)
    }

    @Test func handOffWaitsForTheRestart() {
        let fake = Fake(), store = defaults()
        var handOffs = 0
        let welcome = flow(fake, store)
        welcome.onHandOff = { handOffs += 1 }
        welcome.startIfNeeded()
        welcome.setVolume(true)
        fake.volumeAllowed = true
        welcome.done()
        #expect(handOffs == 0 && fake.asked.contains("restart"))
        fake.volumeApplied = true
        let relaunched = flow(fake, store)
        relaunched.onHandOff = { handOffs += 1 }
        relaunched.startIfNeeded()
        #expect(handOffs == 1 && !relaunched.isShowing)
        let later = flow(fake, store)
        later.onHandOff = { handOffs += 1 }
        later.startIfNeeded()
        #expect(handOffs == 1)
    }

    @Test func aSwitchTurnedOnCheers() async {
        let welcome = flow(Fake())
        welcome.startIfNeeded()
        welcome.setAirPods(true)
        await welcome.setCalendar(true)
        welcome.setAirPods(false)
        #expect(welcome.cheers == 2)
    }

    @Test func dotsGoBackNotForward() {
        let welcome = flow(Fake())
        welcome.startIfNeeded()
        welcome.back(to: .ready)
        #expect(welcome.step == .hello)
        welcome.next(); welcome.next()
        welcome.back(to: .hello)
        #expect(welcome.step == .hello && !welcome.forward)
    }
}

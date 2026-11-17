import Foundation
import Observation

/// The first-launch welcome, round 3 (your picks, 2026-11-11): three short steps in the island's place,
/// Hello · Look · Ready, about 20 seconds.
/// - Hello shows music first (your song if one plays) and moves on when you point at the top of the screen.
/// - Look: Notch, Liquid Glass or Black Pill, applied as you click, so the card itself changes.
/// - Ready: how to reach the rest, then four switches, all off: Meeting reminders, AirPods battery, Brim's volume
///   display, open at login. macOS asks for a permission only when you flip its switch ("fewer asks").
/// Brim's one restart (Accessibility applies when Brim starts) waits for Done. It shows once; Settings → General →
/// Show Welcome Again brings it back.
///
/// The app supplies what the switches do (`Actions`), so this stays free of system frameworks and is tested on its own.
@Observable
public final class WelcomeFlow {
    public enum Step: Int, CaseIterable, Sendable {
        case hello, look, ready
    }

    /// Hello's result, shown for a moment before Look (apple-design: confirm meaningful actions).
    public enum Outcome: Equatable, Sendable {
        case on
    }

    /// The meeting switch: on and off, plus macOS's answer in between.
    public enum CalendarState: Equatable, Sendable {
        case off, asking, on
        /// macOS said no: Settings → Permissions can fix it later.
        case notAllowed
    }

    /// The volume switch: you allow Brim in System Settings, so "on" waits for you there.
    public enum VolumeState: Equatable, Sendable {
        case off
        /// Switched on; System Settings is open and Brim isn't allowed yet.
        case waiting
        case on
    }

    /// What the switches do, supplied by the app.
    public struct Actions {
        /// Turns Calendar on and asks macOS for access (returns when you've answered).
        public var turnOnCalendar: () async -> Void
        public var turnOffCalendar: () -> Void
        public var calendarIsOn: () -> Bool
        /// Turns the AirPods notices on and asks for Bluetooth (macOS answers on its own, later).
        public var turnOnAirPods: () -> Void
        public var turnOffAirPods: () -> Void
        public var airPodsAreOn: () -> Bool
        /// Brim's own volume display on, and, if Brim isn't allowed yet, System Settings opened at Accessibility.
        public var turnOnVolume: () -> Void
        public var turnOffVolume: () -> Void
        /// On and allowed by macOS.
        public var volumeIsOn: () -> Bool
        /// Allowed, but Brim only applies it when it starts: Done restarts.
        public var volumeNeedsRestart: () -> Bool
        /// Quits Brim and opens it again.
        public var restart: () -> Void
        public var launchAtLoginIsOn: () -> Bool
        public var setLaunchAtLogin: (Bool) -> Void

        public init(turnOnCalendar: @escaping () async -> Void, turnOffCalendar: @escaping () -> Void,
                    calendarIsOn: @escaping () -> Bool,
                    turnOnAirPods: @escaping () -> Void, turnOffAirPods: @escaping () -> Void,
                    airPodsAreOn: @escaping () -> Bool,
                    turnOnVolume: @escaping () -> Void, turnOffVolume: @escaping () -> Void,
                    volumeIsOn: @escaping () -> Bool, volumeNeedsRestart: @escaping () -> Bool,
                    restart: @escaping () -> Void, launchAtLoginIsOn: @escaping () -> Bool,
                    setLaunchAtLogin: @escaping (Bool) -> Void) {
            self.turnOnCalendar = turnOnCalendar
            self.turnOffCalendar = turnOffCalendar
            self.calendarIsOn = calendarIsOn
            self.turnOnAirPods = turnOnAirPods
            self.turnOffAirPods = turnOffAirPods
            self.airPodsAreOn = airPodsAreOn
            self.turnOnVolume = turnOnVolume
            self.turnOffVolume = turnOffVolume
            self.volumeIsOn = volumeIsOn
            self.volumeNeedsRestart = volumeNeedsRestart
            self.restart = restart
            self.launchAtLoginIsOn = launchAtLoginIsOn
            self.setLaunchAtLogin = setLaunchAtLogin
        }
    }

    public private(set) var step: Step = .hello
    /// The last move went forward (the next step comes in from the right) or back (from the left).
    public private(set) var forward = true
    /// Set after you point at the top on Hello, until Look shows.
    public private(set) var outcome: Outcome?
    public private(set) var isShowing = false
    public private(set) var calendar: CalendarState = .off
    public private(set) var airPods = false
    public private(set) var volume: VolumeState = .off
    /// Counts switches turned on: Brim winks at each.
    public private(set) var cheers = 0
    /// Done restarts Brim once (you allowed the volume display during the welcome).
    public private(set) var restartPending = false
    /// Ready's last switch, saved when the welcome ends (Skip too: what the screen shows is what you get).
    public var launchAtLogin = true

    /// Showing or hiding, for the window and the island.
    @ObservationIgnored public var onShowingChange: ((Bool) -> Void)?
    /// Done (not Skip): time for the hand-off, the dimmed screen with the arrow pointing at Brim. After Finish &
    /// Restart it comes once Brim is back.
    @ObservationIgnored public var onHandOff: (() -> Void)?
    @ObservationIgnored private let actions: Actions
    @ObservationIgnored private let defaults: UserDefaults
    /// How long Hello's result shows before Look (zero in tests).
    @ObservationIgnored private let resultPause: Duration
    /// Calendar: macOS said no to the last ask (the switch shows Not allowed until you try again).
    @ObservationIgnored private var calendarRefused = false
    @ObservationIgnored private var askingCalendar = false
    /// Volume: switched on during this welcome, so a missing permission reads "waiting", not "off".
    @ObservationIgnored private var volumeAsked = false

    static let finishedKey = "welcome.finished"
    /// Round 2's "Open Settings after the restart" (gone in round 3): cleared at launch if an older Brim left it.
    static let settingsAfterRestartKey = "welcome.openSettingsAfterRestart"
    /// Done restarted Brim: the hand-off shows at the next launch.
    static let handOffPendingKey = "welcome.handOffPending"

    public init(actions: Actions, defaults: UserDefaults = .standard, resultPause: Duration = .milliseconds(900)) {
        self.actions = actions
        self.defaults = defaults
        self.resultPause = resultPause
    }

    /// At launch, on a first launch: the welcome.
    public func startIfNeeded() {
        defaults.removeObject(forKey: Self.settingsAfterRestartKey)
        if defaults.bool(forKey: Self.handOffPendingKey) {
            defaults.removeObject(forKey: Self.handOffPendingKey)
            onHandOff?()
        }
        if !defaults.bool(forKey: Self.finishedKey) { show(firstTime: true) }
    }

    /// Settings → General → Show Welcome Again.
    public func showAgain() { show(firstTime: false) }

    /// Next, and Done on the last step.
    public func next() {
        guard let following = Step(rawValue: step.rawValue + 1) else { return done() }
        move(to: following)
    }

    /// A dot for an earlier step: back to it, nothing undone.
    public func back(to earlier: Step) {
        guard earlier.rawValue < step.rawValue, outcome == nil else { return }
        move(to: earlier)
    }

    /// Skip on Hello: the welcome ends, nothing asked.
    public func skip() { finish(handingOff: false) }

    /// Hello: you pointed at the top of the screen, the one thing worth doing rather than reading.
    public func pointedAtTop() async {
        guard step == .hello, outcome == nil, isShowing else { return }
        outcome = .on
        if resultPause > .zero { try? await Task.sleep(for: resultPause) }
        outcome = nil
        if step == .hello, isShowing { next() }
    }

    /// The meeting switch. On asks macOS (once it has answered, the switch shows what it said).
    public func setCalendar(_ on: Bool) async {
        guard on else {
            actions.turnOffCalendar()
            calendarRefused = false
            refresh()
            return
        }
        guard !askingCalendar else { return }
        askingCalendar = true
        refresh()
        await actions.turnOnCalendar()
        askingCalendar = false
        calendarRefused = !actions.calendarIsOn()
        if !calendarRefused { cheers += 1 }
        refresh()
    }

    /// The AirPods switch: on at once; Settings → Permissions says if macOS refuses Bluetooth later.
    public func setAirPods(_ on: Bool) {
        on ? actions.turnOnAirPods() : actions.turnOffAirPods()
        if on { cheers += 1 }
        refresh()
    }

    /// The volume switch: on opens System Settings if Brim isn't allowed yet; Ready re-checks every second.
    public func setVolume(_ on: Bool) {
        volumeAsked = on
        on ? actions.turnOnVolume() : actions.turnOffVolume()
        if on { cheers += 1 }
        refresh()
    }

    /// Re-reads every switch (Ready asks again while it shows: you allow Brim in System Settings, not here).
    public func refresh() {
        calendar = askingCalendar ? .asking
            : actions.calendarIsOn() ? .on
            : calendarRefused ? .notAllowed : .off
        airPods = actions.airPodsAreOn()
        volume = actions.volumeIsOn() ? .on : volumeAsked ? .waiting : .off
        restartPending = actions.volumeNeedsRestart()
    }

    /// Done, or Finish & Restart.
    public func done() { finish(handingOff: true) }

    private func move(to target: Step) {
        forward = target.rawValue > step.rawValue
        step = target
        refresh()
    }

    private func show(firstTime: Bool) {
        forward = true
        outcome = nil
        step = .hello
        calendarRefused = false
        volumeAsked = false
        // A first launch suggests opening at login; shown again, the switch starts as it is now.
        launchAtLogin = firstTime || actions.launchAtLoginIsOn()
        refresh()
        guard !isShowing else { return }
        isShowing = true
        onShowingChange?(true)
    }

    private func finish(handingOff: Bool) {
        defaults.set(true, forKey: Self.finishedKey)
        if launchAtLogin != actions.launchAtLoginIsOn() { actions.setLaunchAtLogin(launchAtLogin) }
        let restarting = actions.volumeNeedsRestart()
        if isShowing {
            isShowing = false
            onShowingChange?(false)
        }
        if restarting {
            if handingOff { defaults.set(true, forKey: Self.handOffPendingKey) }
            actions.restart()
        } else if handingOff {
            onHandOff?()
        }
    }
}

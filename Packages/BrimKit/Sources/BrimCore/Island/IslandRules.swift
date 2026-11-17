import Foundation

/// What the island is showing. The coordinator publishes exactly one of these at a time.
public enum IslandSurface: Equatable, Sendable {
    case hidden
    /// The kept music indicator as a thin line at the top edge (Settings → "Slim line").
    case slim
    case compact(IslandActivity.Kind)
    case expanded(ExpandedPage)
}

extension IslandSurface {
    public var isExpanded: Bool {
        if case .expanded = self { return true }
        return false
    }

    /// Volume or brightness.
    public var isHUD: Bool {
        if case .compact(.hud) = self { return true }
        return false
    }
}

/// The open island's tabs (decision 7, 2026-09-30): each is a whole page for one job.
public enum ExpandedPage: Equatable, Sendable, CaseIterable {
    /// Now Playing: artwork, progress, controls, lyrics.
    case music
    /// Timers: Focus | Break, the ruler, the running timers.
    case timers
    /// Calendar: the time and date, your day's events.
    case calendar
}

/// A short-lived reason to show the island, such as "the track changed" or "the volume changed".
public struct IslandActivity: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The song's title in the 320 pt glance. Not posted since 0.17.4: music never widens the island (your pick,
        /// 2026-10-02). Kept as the plainest glance for the rules' tests.
        case nowPlaying
        /// The kept-visible pill: artwork and waveform only (your picks, 2026-09-30). Never an activity.
        case keptMusic
        /// Volume or brightness changed.
        case hud(HUDKind)
        /// The Mac was plugged in, got full, or Low Power Mode changed (P-4).
        case battery
        /// Headphones connected: their battery (P-4).
        case headphones
        /// An event starts in 5 minutes (P-4, F8).
        case calendar
        /// The running timer on its own, when you swiped it on and no music pill is showing (F9). Never an activity.
        case timer
        /// "5 min left" / "1 min left" (F9).
        case timerNotice
        /// "Time's up": stays until you stop it, 30 s at most (F9).
        case timerDone
        /// Keep-awake is on and nothing else rests: a small coffee pill (F11). Never an activity.
        case keepAwake
        /// Nothing plays and nothing else rests: Brim asleep, a small pill with closed eyes, so it never vanishes
        /// (your pick, 2026-11-11). Never an activity.
        case resting
    }

    public var kind: Kind
    /// Higher wins when two activities want the island at the same time.
    public var priority: Int
    public var start: Date
    public var duration: TimeInterval
    public var expiresAt: Date { start.addingTimeInterval(duration) }

    /// Waits for its turn behind a higher glance, then gets its full time, instead of expiring unseen
    /// (docs/05-interaction-model.md). The HUD is instant feedback and a song change is old news a moment
    /// later, so those two don't wait.
    public var waitsForTurn: Bool {
        switch kind {
        case .battery, .headphones, .calendar, .timerNotice, .timerDone: true
        case .hud, .nowPlaying, .keptMusic, .timer, .keepAwake, .resting: false
        }
    }

    public init(kind: Kind, priority: Int, start: Date, duration: TimeInterval) {
        self.kind = kind
        self.priority = priority
        self.start = start
        self.duration = duration
    }

    /// The song glance (not posted since 0.17.4, see `Kind.nowPlaying`): 3 s, lowest priority of all.
    public static func nowPlaying(at date: Date) -> IslandActivity {
        IslandActivity(kind: .nowPlaying, priority: 10, start: date, duration: 3)
    }

    /// PRD F10: a battery notice for 3 s; above a new song, below the HUD.
    public static func battery(at date: Date) -> IslandActivity {
        IslandActivity(kind: .battery, priority: 50, start: date, duration: 3)
    }

    /// P-4 (PRD F8): "Class · in 5 min" + Join, for 6 s. Above device notices, below the HUD.
    public static func calendar(at date: Date) -> IslandActivity {
        IslandActivity(kind: .calendar, priority: 70, start: date, duration: 6)
    }

    /// PRD F9: "5 min left" and "1 min left", 3 s each.
    public static func timerNotice(at date: Date) -> IslandActivity {
        IslandActivity(kind: .timerNotice, priority: 65, start: date, duration: 3)
    }

    /// PRD F9 + state table: "Time's up" until you stop it, 30 s at most. Below the HUD, so a volume change
    /// still shows over it for a moment.
    public static func timerDone(at date: Date) -> IslandActivity {
        IslandActivity(kind: .timerDone, priority: 85, start: date, duration: 30)
    }

    /// P-4 (PRD F7): headphones connected, for 3 s; disconnected, briefly (1.5 s).
    public static func headphones(at date: Date, disconnected: Bool = false) -> IslandActivity {
        IslandActivity(kind: .headphones, priority: 60, start: date, duration: disconnected ? 1.5 : 3)
    }

    /// PRD §3: HUD for 1.5 s after the last change. Each new change restarts the 1.5 s.
    public static func hud(_ kind: HUDKind, at date: Date) -> IslandActivity {
        IslandActivity(kind: .hud(kind), priority: 90, start: date, duration: 1.5)
    }
}

/// Whether anything is playing. Decides what a kept-visible pill does.
public enum MediaPresence: Equatable, Sendable {
    case none
    case playing
    case paused(since: Date)
}

/// Everything the rules need to decide what to show.
public struct IslandState: Equatable, Sendable {
    public var isHovering = false
    public var hoverEndedAt: Date?
    public var activities: [IslandActivity] = []
    public var media: MediaPresence = .none
    /// Settings → Island → "Keep music visible".
    public var keepPillVisible = false
    /// Settings → Island → "Show it as": the full pill, or a slim line that covers nothing.
    public var keptStyle: KeptStyle = .pill
    /// The front app's window is in macOS full screen (your report, 2026-10-02: the pill drew the eye there).
    public var frontIsFullScreen = false
    /// Settings → Island → "In full-screen apps": hide (the default, 2026-10-02) or the slim line.
    public var fullScreen: FullScreenIsland = .hide
    /// Over a full-screen window you keep clear: nothing rests, and only important notices show.
    public var fullScreenHides: Bool { frontIsFullScreen && fullScreen == .hide }
    /// A macOS Focus's Brim filter (feature 2, your picks 2026-10-02): its island, nil when no such Focus is on.
    public var focusIsland: FocusIsland?
    /// That Focus wants only important notices: what a Brim Focus timer lets through (decision 11).
    public var focusImportantOnly = false
    /// What rests: the slim line over a full-screen window if you chose it (never the pill there; with Hide nothing
    /// rests, see `surface`), else the Focus's choice, else yours.
    public var restingStyle: KeptStyle {
        if frontIsFullScreen && fullScreen == .slimLine { return .slimLine }
        switch focusIsland {
        case .pill?: return .pill
        case .slimLine?: return .slimLine
        case .hidden?, nil: return keptStyle
        }
    }
    /// Only calendar reminders, Time's up and the HUD interrupt: a Brim Focus timer counts down, a macOS Focus asks,
    /// or a full-screen window is kept clear.
    public var quiet: Bool { focusing || focusImportantOnly || fullScreenHides }
    /// The full-screen player is open: the island stays out of its way (PRD §3).
    public var fullScreenPlayerOpen = false
    /// The first-launch welcome is showing in the island's place: the island stays hidden until it ends.
    public var welcomeOpen = false
    /// A timer is running (F9): its ring rests beside the music pill, or it rests as the pill on its own.
    public var timerRunning = false
    /// A Focus timer is counting down: only what `getsThroughFocus` may interrupt (decision 11).
    public var focusing = false
    /// The tab you picked while the island is open (or the one a side bubble opens).
    public var openPage: ExpandedPage?
    /// The tab you used last: the island opens on it when nothing plays (on Music when something does).
    public var lastTab: ExpandedPage = .calendar
    /// Keep-awake is on (F11): the coffee rides on the pill's left, or rests on its own.
    public var keepAwake = false
    /// Settings → Island → "When nothing plays" (2026-11-11): Brim rests asleep, or as the slim line, or hides.
    public var idleStyle: IdleStyle = .hidden

    public init() {}

    public var hasMedia: Bool { media != .none }
}

/// Settings → Island → "When nothing plays" (your pick, 2026-11-11: Brim should never just vanish).
public enum IdleStyle: String, Equatable, Sendable, CaseIterable {
    /// A small pill with Brim's closed eyes.
    case asleep
    /// The slim line: covers nothing.
    case slimLine = "slim"
    /// Nothing, as before 0.33: Brim shows only when something happens or you point at the top.
    case hidden

    public var title: String {
        switch self {
        case .asleep: "Brim asleep"
        case .slimLine: "Slim line"
        case .hidden: "Hidden"
        }
    }
}

/// How a macOS Focus wants Brim's island (its Brim filter in System Settings → Focus).
public enum FocusIsland: String, Equatable, Sendable, CaseIterable {
    case pill, slimLine, hidden
}

/// The island's behaviour as pure functions: same input, same output, so every rule is unit-tested.
public enum IslandRules {
    /// How long the island stays open after the pointer leaves it (PRD §3).
    public static let hoverGrace: TimeInterval = 0.6
    /// A kept-visible pill hides once the music has been paused this long (your choice: 1 minute).
    public static let pausedPillTimeout: TimeInterval = 60

    /// In order: your hover → the highest live activity → the kept pill (or slim line) → hidden.
    /// (While you hover, a HUD appears inside the open island instead of replacing it.)
    public static func surface(for state: IslandState, at now: Date) -> IslandSurface {
        if state.fullScreenPlayerOpen || state.welcomeOpen { return .hidden }
        if state.isHovering || isInGrace(state, at: now) {
            // The tab you picked (or a side bubble opened); else Music when something plays, else your last tab.
            let usual: ExpandedPage = state.hasMedia ? .music : (state.lastTab == .music ? .calendar : state.lastTab)
            return .expanded(state.openPage ?? usual)
        }
        if let top = liveActivities(state.activities, at: now).first {
            return .compact(top.kind)
        }
        // A Focus that hides the island, or a full-screen window kept clear: nothing rests (music, timers,
        // keep-awake); the glances that get through and opening still work.
        if state.focusIsland == .hidden || state.fullScreenHides { return .hidden }
        if showsKeptPill(state, at: now) {
            // The pill, with a running timer's ring beside it; or the slim line you chose to cover nothing, carrying
            // a mark for each Live Activity (your pick A, 2026-09-30).
            return state.restingStyle == .pill ? .compact(.keptMusic) : .slim
        }
        // Slim line chosen: timers and keep-awake stay on the line as marks, never the pill (it would cover the
        // toolbar you chose the line to keep clear).
        if state.restingStyle == .slimLine, state.timerRunning || state.keepAwake { return .slim }
        // With no music resting, a running timer takes the centre (research item 9); with neither, keep-awake shows
        // as a small coffee pill, so you can always see it's on.
        if state.timerRunning { return .compact(.timer) }
        if state.keepAwake { return .compact(.keepAwake) }
        // Nothing to show: Brim rests asleep in its small pill, or as the slim line that covers nothing (your choice;
        // never the pill where a Focus or a full-screen window asks for the line). Not while music plays with "Keep
        // music visible" off: that choice means "nothing over my music".
        guard state.idleStyle != .hidden, state.media != .playing else { return .hidden }
        let lineAsked = (state.frontIsFullScreen && state.fullScreen == .slimLine) || state.focusIsland == .slimLine
        return state.idleStyle == .asleep && !lineAsked ? .compact(.resting) : .slim
    }

    /// The tab the island opens on when you open it from a Live Activity in the pill: its own tab, even while
    /// music is loaded (your report, 2026-10-02: clicking the timer opened Music). Nil: the usual tab.
    public static func page(opening surface: IslandSurface) -> ExpandedPage? {
        switch surface {
        case .compact(.timer), .compact(.timerNotice), .compact(.timerDone): .timers
        case .compact(.calendar): .calendar
        default: nil
        }
    }

    /// Kept pill: visible while playing, and for up to a minute after pausing.
    public static func showsKeptPill(_ state: IslandState, at now: Date) -> Bool {
        guard state.keepPillVisible else { return false }
        switch state.media {
        case .none: return false
        case .playing: return true
        case .paused(let since): return now < since.addingTimeInterval(pausedPillTimeout)
        }
    }

    /// Glances that wait for their turn start when the one above them ends, with their full time.
    /// Applied at every evaluation, so a HUD that keeps going (each key press) keeps pushing them back.
    public static func queued(_ activities: [IslandActivity], at now: Date) -> [IslandActivity] {
        guard let top = liveActivities(activities, at: now).first else { return activities }
        return activities.map { activity in
            guard activity.waitsForTurn, activity != top, activity.priority < top.priority,
                  activity.expiresAt > now, activity.start < top.expiresAt else { return activity }
            var waiting = activity
            waiting.start = top.expiresAt
            return waiting
        }
    }

    /// Activities that haven't expired, highest priority first; the newest wins a tie.
    public static func liveActivities(_ activities: [IslandActivity], at now: Date) -> [IslandActivity] {
        activities
            .filter { $0.expiresAt > now }
            .sorted { ($0.priority, $0.start) > ($1.priority, $1.start) }
    }

    /// The next moment `surface(for:at:)` can change by itself: an activity expiring, the hover grace
    /// ending, or a paused pill timing out. `nil` means only a new event can change it.
    public static func nextChange(for state: IslandState, after now: Date) -> Date? {
        var candidates = liveActivities(state.activities, at: now).map(\.expiresAt)
        if !state.isHovering, let ended = state.hoverEndedAt {
            let graceEnd = ended.addingTimeInterval(hoverGrace)
            if graceEnd > now { candidates.append(graceEnd) }
        }
        if state.keepPillVisible, case .paused(let since) = state.media {
            let pillEnd = since.addingTimeInterval(pausedPillTimeout)
            if pillEnd > now { candidates.append(pillEnd) }
        }
        return candidates.min()
    }

    private static func isInGrace(_ state: IslandState, at now: Date) -> Bool {
        guard !state.isHovering, let ended = state.hoverEndedAt else { return false }
        return now < ended.addingTimeInterval(hoverGrace)
    }
}

extension IslandActivity.Kind {
    /// Focus means quiet (docs/05-interaction-model.md, decision 11, your pick 2026-10-01): while a Focus timer runs,
    /// only a calendar reminder and Time's up interrupt, plus the volume/brightness HUD (you pressed the key). The
    /// rest (music starting, battery, AirPods, "5 / 1 min left") is skipped, not queued: the ring shows the time.
    public var getsThroughFocus: Bool {
        switch self {
        case .calendar, .timerDone, .hud: true
        case .nowPlaying, .battery, .headphones, .timerNotice, .keptMusic, .timer, .keepAwake, .resting: false
        }
    }
}

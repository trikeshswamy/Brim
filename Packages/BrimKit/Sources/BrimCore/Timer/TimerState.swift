import Foundation

/// The one timer (F9). Stored as an end time, so it survives sleep and relaunch (PRD F9).
public struct TimerState: Codable, Equatable, Sendable {
    /// Its length so far: the preset plus any "+1 min" (for "of 25 min" and the ring).
    public var total: TimeInterval
    /// Running: when it ends.
    public var endsAt: Date?
    /// Paused: what's left.
    public var pausedRemaining: TimeInterval?

    /// The open island's buttons (PRD F9: 5, 15, 25 or 45 minutes in 2 clicks).
    public static let presets = [5, 15, 25, 45]

    public init(total: TimeInterval, endsAt: Date?, pausedRemaining: TimeInterval? = nil) {
        self.total = total
        self.endsAt = endsAt
        self.pausedRemaining = pausedRemaining
    }

    public static func start(length: TimeInterval, at now: Date) -> TimerState {
        TimerState(total: length, endsAt: now.addingTimeInterval(length))
    }

    public var isPaused: Bool { pausedRemaining != nil }

    public func remaining(at now: Date) -> TimeInterval {
        if let pausedRemaining { return max(0, pausedRemaining) }
        guard let endsAt else { return 0 }
        return max(0, endsAt.timeIntervalSince(now))
    }

    public func hasEnded(at now: Date) -> Bool { !isPaused && remaining(at: now) <= 0 }

    /// 1 at the start, 0 at the end: how full the ring is.
    public func share(at now: Date) -> Double { total > 0 ? remaining(at: now) / total : 0 }

    public func paused(at now: Date) -> TimerState {
        guard !isPaused else { return self }
        return TimerState(total: total, endsAt: nil, pausedRemaining: remaining(at: now))
    }

    public func resumed(at now: Date) -> TimerState {
        guard let pausedRemaining else { return self }
        return TimerState(total: total, endsAt: now.addingTimeInterval(pausedRemaining))
    }

    public func addingMinute() -> TimerState {
        var next = self
        next.total += 60
        next.endsAt = endsAt?.addingTimeInterval(60)
        next.pausedRemaining = pausedRemaining.map { $0 + 60 }
        return next
    }

    /// "25 min" for the notices; "1 min 40 s" when it isn't whole minutes (the 100 s test timer said "2 min");
    /// "1 h 4 min" from an hour up.
    public var lengthText: String {
        let seconds = Int(total.rounded())
        if seconds >= 3600 {
            let hours = seconds / 3600, minutes = (seconds % 3600) / 60
            return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
        }
        switch (seconds / 60, seconds % 60) {
        case (0, let s): return "\(s) s"
        case (let m, 0): return "\(m) min"
        case (let m, let s): return "\(m) min \(s) s"
        }
    }
}

/// Focus or Break (your pick, 2026-09-30): what a timer is for, and where the ruler starts.
public enum TimerKind: String, Codable, Sendable, CaseIterable {
    case focus
    /// "Break" (`break` is a Swift keyword).
    case rest

    public var title: String { self == .focus ? "Focus" : "Break" }
    public var defaultMinutes: Int { self == .focus ? 25 : 5 }
}

/// One of up to five timers (decision 7, 2026-09-30).
public struct TimerItem: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: TimerKind
    public var state: TimerState
    /// "5 min left" / "1 min left" already shown for this timer.
    public var shownMilestones: Set<Int>
    /// When you started it, for Focus history (nil for timers saved before 0.17).
    public var startedAt: Date?
    /// What a Focus timer is for (feature 3): picked with "For:" next to Start.
    public var label: String?

    public init(id: UUID = UUID(), kind: TimerKind, state: TimerState, shownMilestones: Set<Int> = [],
                startedAt: Date? = nil, label: String? = nil) {
        self.id = id
        self.kind = kind
        self.state = state
        self.shownMilestones = shownMilestones
        self.startedAt = startedAt
        self.label = label
    }
}

/// The timer's words and moments. Pure, so tested.
public enum TimerRules {
    /// At most five at once: a focus session, the laundry, the tea… (decision 7).
    public static let maximumTimers = 5

    /// You're focusing: a Focus timer is counting down (a paused one, or only a Break, doesn't count). Decision 11.
    public static func isFocusing(_ items: [TimerItem]) -> Bool {
        items.contains { $0.kind == .focus && !$0.state.isPaused }
    }

    /// The timer the pill and its ring show: the running one that ends first; a paused one only when none run.
    public static func soonest(_ items: [TimerItem], at now: Date) -> TimerItem? {
        let running = items.filter { !$0.state.isPaused }
        return (running.isEmpty ? items : running).min { $0.state.remaining(at: now) < $1.state.remaining(at: now) }
    }

    /// The next moment any timer needs Brim: a "N min left" notice or an end.
    public static func nextEvent(in items: [TimerItem], at now: Date) -> (id: UUID, milestone: Int?, at: Date)? {
        var best: (id: UUID, milestone: Int?, at: Date)?
        for item in items {
            guard let endsAt = item.state.endsAt else { continue }  // paused
            var candidate: (id: UUID, milestone: Int?, at: Date) = (item.id, nil, endsAt)
            if let notice = nextMilestone(for: item.state, at: now, shown: item.shownMilestones), notice.at < endsAt {
                candidate = (item.id, notice.minutes, notice.at)
            }
            if best.map({ candidate.at < $0.at }) ?? true { best = candidate }
        }
        return best
    }

    /// The ruler's labels: "25" under an hour, then "1h", "1:30".
    public static func rulerLabel(minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes)" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours):" + String(format: "%02d", rest)
    }

    /// Where the ruler comes to rest: whole ticks only. With half the width minus half a tick of space at each end,
    /// a whole-tick offset puts a tick's centre exactly under the pointer (0.13.2; it used to stop on a tick's edge).
    public static func rulerSnap(_ offset: CGFloat, tickWidth: CGFloat) -> CGFloat {
        guard tickWidth > 0 else { return offset }
        return max(0, (offset / tickWidth).rounded() * tickWidth)
    }

    /// Brief notices at 5 and 1 minute left (PRD F9).
    public static let milestones = [5, 1]

    /// The next "N min left" notice. Skipped when the timer started with about that much or less
    /// (a 5-minute timer doesn't say "5 min left" as it starts), and once shown or passed.
    public static func nextMilestone(for state: TimerState, at now: Date, shown: Set<Int>) -> (minutes: Int, at: Date)? {
        guard let endsAt = state.endsAt else { return nil }  // paused: nothing is coming
        return milestones
            .filter { !shown.contains($0) && state.total > TimeInterval($0 * 60) + 30 }
            .map { (minutes: $0, at: endsAt.addingTimeInterval(-TimeInterval($0 * 60))) }
            .filter { $0.at > now }
            .min { $0.at < $1.at }
    }

    /// "24:13", or "1:04:10" from an hour up; rounds up, so it reads 25:00 at the start and 0:01 in the last second.
    public static func clock(_ remaining: TimeInterval) -> String {
        let seconds = Int(remaining.rounded(.up))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The ring bubble's label: the clock's minutes ("24" at 24:13), then seconds in the last minute ("45s").
    public static func bubbleLabel(_ remaining: TimeInterval) -> String {
        let seconds = Int(remaining.rounded(.up))
        if seconds >= 3600 { return "\(seconds / 3600)h" }
        return seconds >= 60 ? "\(seconds / 60)" : "\(seconds)s"
    }
}

/// The end of a timer: a sound and a notification (PRD F9). Live: NSSound + UserNotifications; tests: a fake.
@MainActor
public protocol TimerAlarm: AnyObject {
    /// Asks for notification permission, the first time a timer starts.
    func prepare()
    func ring(title: String, body: String)
    func silence()
}

/// A two-finger swipe on the island (PRD F9 and the gestures table): a whole gesture, fingers down to up,
/// mostly sideways. Either direction toggles the timer (the PRD's default; revisit after you've tried it).
/// The pair beside the controls follows your fingers (your pick, 2026-11-16): the swipe is a position between the
/// pages, 0 (Shuffle & Repeat) to 1 (Favorite & Output), and every button and dot is drawn from it.
public enum SidePaging {
    /// Points of finger travel for a whole page.
    public static let pageTravel = 90.0
    /// How far past the last page you can pull: a little, harder the further (like any Mac scroll's edge).
    public static let stretch = 0.16
    /// A flick switches with less travel: this fast (points of finger travel a second), past this share of a page.
    public static let flickSpeed = 350.0
    public static let flickShare = 0.12

    /// Where the pages are while your fingers move: `page` 0 or 1, `fingerDX` how far they moved (right is +).
    /// Fingers moving left bring the right page in, like a carousel.
    public static func position(page: Int, fingerDX: Double) -> Double {
        let raw = Double(page) - fingerDX / pageTravel
        if raw < 0 { return -stretch * (1 - 1 / (1 - raw * 3)) }
        if raw > 1 { return 1 + stretch * (1 - 1 / (1 + (raw - 1) * 3)) }
        return raw
    }

    /// The page you land on when your fingers lift: past halfway, or a quick flick toward the other one.
    /// `velocity`: finger speed, right is +.
    public static func landing(page: Int, position: Double, velocity: Double) -> Int {
        let moved = position - Double(page)          // + toward page 1
        let toward = page == 0 ? moved > 0 : moved < 0
        guard toward else { return page }
        let flick = (page == 0 ? -velocity : velocity) >= flickSpeed && abs(moved) >= flickShare
        return abs(moved) >= 0.5 || flick ? 1 - page : page
    }

    /// How much of a page's buttons show at `position` (1 on its page, 0 a whole page away).
    public static func visibility(of page: Int, at position: Double) -> Double {
        max(0, 1 - abs(Double(page) - position))
    }
}

public enum SwipeRules {
    /// Scroll distance, in points of trackpad travel: a deliberate swipe gives 100–300, a brush under 20.
    public static let minimumTravel = 30.0

    public static func isSideways(dx: Double, dy: Double) -> Bool {
        abs(dx) >= minimumTravel && abs(dx) > 2 * abs(dy)
    }
}

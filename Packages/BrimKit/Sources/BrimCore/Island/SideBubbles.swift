import Foundation

/// What rides beside the resting pill (decision 8, 2026-09-30): keep-awake on the left (a mode that's on);
/// countdowns on the right (timers, a class starting within 10 minutes), the soonest first, "+N" for the rest.
/// With keep-awake off, the next countdown takes the empty left side instead of hiding in "+1" (your pick,
/// 2026-11-16: a timer and a meeting showed "1 +1", the timer nowhere).
public struct SideBubbles: Equatable, Hashable, Sendable {
    public enum Countdown: Equatable, Hashable, Sendable {
        case timer(UUID)
        /// A calendar event's id.
        case event(String)
    }

    /// Keep-awake, on the left.
    public var left: Bool
    public var right: Countdown?
    /// The second countdown, on the left while keep-awake is off.
    public var leftCountdown: Countdown?
    /// Countdowns not shown: the "+N" badge on the right bubble.
    public var more: Int

    public init(left: Bool = false, right: Countdown? = nil, leftCountdown: Countdown? = nil, more: Int = 0) {
        self.left = left
        self.right = right
        self.leftCountdown = left ? nil : leftCountdown
        self.more = more
    }

    /// Something shows on the left: keep-awake or a countdown.
    public var hasLeft: Bool { left || leftCountdown != nil }

    public static let none = SideBubbles()

    /// Without the sides you swiped away. The right side goes with its "+N": another countdown mustn't slide into
    /// the place you just cleared.
    public func hiding(_ sides: Set<BubbleSide>) -> SideBubbles {
        var shown = self
        if sides.contains(.left) { shown.left = false; shown.leftCountdown = nil }
        if sides.contains(.right) { shown.right = nil; shown.more = 0 }
        return shown
    }
}

/// The two places beside the pill: keep-awake on the left, countdowns on the right.
public enum BubbleSide: Hashable, Sendable {
    case left, right
}

/// One thing that can ride beside the pill: keep-awake, or a countdown.
public enum SideActivity: Hashable, Sendable {
    case keepAwake
    case countdown(SideBubbles.Countdown)

    public var side: BubbleSide { self == .keepAwake ? .left : .right }
}

public enum SideRules {
    /// A class shows its countdown from 10 minutes before it starts.
    public static let classWindow: TimeInterval = 10 * 60

    /// The resting shapes bubbles ride beside: the music pill (or the HUD in its place, same size) or the timer pill.
    /// Never beside a glance, the slim line, the coffee pill on its own, or the open island.
    public static func showsBubbles(beside surface: IslandSurface) -> Bool {
        surface == .compact(.keptMusic) || surface.isHUD || surface == .compact(.timer)
    }

    /// Everything that could ride beside the pill now: keep-awake, each timer, a class in its last 10 minutes.
    public static func activities(keepAwake: Bool, timers: [UUID], soonEvent: String?) -> Set<SideActivity> {
        var all = Set(timers.map { SideActivity.countdown(.timer($0)) })
        if keepAwake { all.insert(.keepAwake) }
        if let soonEvent { all.insert(.countdown(.event(soonEvent))) }
        return all
    }

    /// The sides where something started since `before`: a timer or a class entering its 10 minutes (right), keep-awake
    /// turning on (left). Each brings its own side back if you swiped it away (decision 9). Something ending isn't new.
    public static func newSides(_ now: Set<SideActivity>, since before: Set<SideActivity>) -> Set<BubbleSide> {
        Set(now.subtracting(before).map(\.side))
    }

    /// Your two-finger swipe (decision 9, your fix round 2): on a bubble it hides that bubble's side only; on the pill
    /// it brings hidden bubbles back. `available`: what would show if nothing were hidden. Nil: nothing changes (no tick).
    public static func afterSwipe(on side: BubbleSide?, available: SideBubbles, hidden: Set<BubbleSide>) -> Set<BubbleSide>? {
        switch side {
        case .left?:
            return available.hasLeft && !hidden.contains(.left) ? hidden.union([.left]) : nil
        case .right?:
            return available.right != nil && !hidden.contains(.right) ? hidden.union([.right]) : nil
        case nil:
            // The pill flips them all (your pick, 2026-10-01): any hidden → all come back; all showing → all hide.
            let comingBack = hidden.filter { $0 == .left ? available.hasLeft : available.right != nil }
            if !comingBack.isEmpty { return [] }
            var showing: Set<BubbleSide> = []
            if available.hasLeft { showing.insert(.left) }
            if available.right != nil { showing.insert(.right) }
            return showing.isEmpty ? nil : hidden.union(showing)
        }
    }

    /// - timers: each timer's end (nil while paused: those count last).
    /// - centreTimer: the timer the pill itself shows when no music rests; it isn't repeated beside the pill.
    public static func bubbles(keepAwake: Bool, timers: [(id: UUID, endsAt: Date?)], soonEvent: (id: String, start: Date)?,
                               centreTimer: UUID?, now: Date) -> SideBubbles {
        var countdowns: [(countdown: SideBubbles.Countdown, at: Date)] = timers
            .filter { $0.id != centreTimer }
            .map { (countdown: .timer($0.id), at: $0.endsAt ?? .distantFuture) }
        if let soonEvent, soonEvent.start > now, soonEvent.start.timeIntervalSince(now) <= classWindow {
            countdowns.append((countdown: .event(soonEvent.id), at: soonEvent.start))
        }
        countdowns.sort { $0.at < $1.at }
        let second = keepAwake || countdowns.count < 2 ? nil : countdowns[1].countdown
        return SideBubbles(left: keepAwake, right: countdowns.first?.countdown, leftCountdown: second,
                           more: max(0, countdowns.count - (second == nil ? 1 : 2)))
    }
}

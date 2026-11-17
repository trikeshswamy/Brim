import SwiftUI
import BrimCore

/// The side bubbles for what's true right now: the island draws them, the window makes them clickable.
@MainActor
public enum IslandSides {
    /// `hiding`: the sides you swiped away (decision 9); leave it empty to ask what would show.
    public static func current(surface: IslandSurface, timer: TimerStore?, calendar: CalendarStore?, keepAwake: Bool,
                               hiding: Set<BubbleSide> = [], now: Date = Date()) -> SideBubbles {
        // Only beside something resting: the music pill (or the HUD in its place, same size) or the timer pill.
        guard SideRules.showsBubbles(beside: surface) else { return .none }
        let centre = surface == .compact(.timer) ? timer?.soonest?.id : nil
        return SideRules.bubbles(keepAwake: keepAwake,
                                 timers: timer?.items.map { (id: $0.id, endsAt: $0.state.endsAt) } ?? [],
                                 soonEvent: calendar?.soon.map { (id: $0.id, start: $0.start) },
                                 centreTimer: centre, now: now)
            .hiding(hiding)
    }
}

extension IslandSides {
    /// The slim line's marks (your pick A, 2026-09-30): keep-awake on the left, the soonest countdown on the right.
    /// Every countdown counts (the slim line has no centre timer); the rest are in the open island.
    public static func slimMarks(timer: TimerStore?, calendar: CalendarStore?, keepAwake: Bool, now: Date = Date()) -> SideBubbles {
        SideRules.bubbles(keepAwake: keepAwake, timers: timer?.items.map { (id: $0.id, endsAt: $0.state.endsAt) } ?? [],
                          soonEvent: calendar?.soon.map { (id: $0.id, start: $0.start) }, centreTimer: nil, now: now)
    }

    /// How much of a countdown is left, 1 → 0: a timer's share, or a class's minutes out of its 10.
    static func share(of countdown: SideBubbles.Countdown, timer: TimerStore?, calendar: CalendarStore?, at date: Date) -> Double {
        switch countdown {
        case .timer(let id):
            return timer?.items.first { $0.id == id }?.state.share(at: date) ?? 0
        case .event:
            guard let start = calendar?.soon?.start else { return 0 }
            return min(max(start.timeIntervalSince(date) / SideRules.classWindow, 0), 1)
        }
    }
}

/// The two bubbles beside the resting pill (decision 8). Each is pulled out from behind the pill's end and pushed
/// back in when it goes. They're drawn under the pill and masked to outside its outline, so on see-through glass
/// they truly come from behind it.
struct SideBubblesLayer: View {
    let sides: SideBubbles
    let appearance: IslandAppearance
    let timer: TimerStore?
    let calendar: CalendarStore?
    var keepAwake: KeepAwakeStore?
    var geometry: IslandDisplayGeometry = .reference
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ring = IslandMetrics.timerBubble(appearance: appearance, geometry: geometry)
        let pill = IslandMetrics.pillSize(appearance: appearance, geometry: geometry)
        let tucked = pill.width / 2 - ring.side / 2
        ZStack(alignment: .top) {
            if sides.left {
                placed(bubble { KeepAwakeBubbleView(store: keepAwake, edgeToEdge: appearance == .black) }, tucked: -tucked,
                       settled: -ring.centreOffset)
            } else if let left = sides.leftCountdown {
                // The second countdown, with keep-awake off (your pick, 2026-11-16).
                placed(bubble { countdownContent(left) }, tucked: -tucked, settled: -ring.centreOffset)
                    .id(left)
            }
            if let right = sides.right {
                placed(bubble { countdownContent(right) }.overlay(alignment: .topTrailing) { badge }, tucked: tucked,
                       settled: ring.centreOffset)
                    .id(right)  // a different countdown pulls out afresh
            }
        }
        .frame(width: IslandMetrics.panelSize.width, height: IslandMetrics.panelSize.height, alignment: .top)
        .mask { Self.outsideThePill(pill, appearance: appearance, geometry: geometry) }
        .allowsHitTesting(false)  // clicks arrive through the window (see IslandWindowController)
    }

    /// Going out: the pull-out you approved (a spring with a little overshoot). Going back in (your note, 2026-09-30:
    /// in Black it "doesn't go in fully in one smooth motion, it pauses, then hides"): it shrinks toward the pill's
    /// middle, so nothing is left peeking out below the notch's rounded corner (see `PullOut`).
    @ViewBuilder
    private func placed(_ view: some View, tucked: CGFloat, settled: CGFloat) -> some View {
        if reduceMotion {
            view.modifier(PullOutEffect(progress: 1, tucked: tucked, settled: settled)).transition(.opacity)
        } else {
            view.transition(PullOut(tucked: tucked, settled: settled,
                                    lift: Self.tuckLift(appearance: appearance, geometry: geometry)))
        }
    }

    /// How far a tucking bubble rises to sit on the pill's middle: Black's bubble floats 4 pt below the edge, lower than
    /// the notch's middle; Glass's is already centred on the pill.
    static func tuckLift(appearance: IslandAppearance, geometry: IslandDisplayGeometry = .reference) -> CGFloat {
        guard appearance == .black else { return 0 }
        let ring = IslandMetrics.timerBubble(appearance: appearance, geometry: geometry)
        return ring.top + ring.side / 2 - IslandMetrics.pillSize(appearance: appearance, geometry: geometry).height / 2
    }

    private func bubble(@ViewBuilder _ content: () -> some View) -> some View {
        let ring = IslandMetrics.timerBubble(appearance: appearance, geometry: geometry)
        return Group {
            if appearance == .black {
                content().frame(width: ring.side, height: ring.side)
            } else {
                content()
                    .frame(width: ring.side, height: ring.side)
                    .modifier(IslandSurfaceStyle(appearance: appearance, cornerRadius: ring.side / 2, shoulder: 0))
            }
        }
        .padding(.top, ring.top)
    }

    @ViewBuilder
    private func countdownContent(_ countdown: SideBubbles.Countdown) -> some View {
        switch countdown {
        case .timer(let id):
            if let timer { TimerBubbleView(timer: timer, itemID: id, edgeToEdge: appearance == .black) }
        case .event:
            if let event = calendar?.soon { ClassBubbleView(event: event, edgeToEdge: appearance == .black) }
        }
    }

    @ViewBuilder
    private var badge: some View {
        if sides.more > 0 {
            Text("+\(sides.more)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 4)
                .frame(height: 14)
                .background(Color.orange, in: Capsule())
                .offset(x: 6, y: -2)
        }
    }

    /// Everything except the pill's own outline.
    static func outsideThePill(_ pill: CGSize, appearance: IslandAppearance,
                               geometry: IslandDisplayGeometry = .reference) -> some View {
        ZStack(alignment: .top) {
            Rectangle()
            Group {
                if appearance == .black {
                    NotchShape(bottomRadius: pill.height / 2,
                               shoulder: IslandMetrics.notchShoulder(for: .compact(.keptMusic), geometry: geometry))
                        .frame(width: pill.width + 2 * IslandMetrics.notchShoulder(for: .compact(.keptMusic), geometry: geometry),
                               height: pill.height)
                } else {
                    Capsule()
                        .frame(width: pill.width, height: pill.height)
                        .padding(.top, IslandMetrics.topGap(for: .compact(.keptMusic), appearance: appearance))
                }
            }
            .blendMode(.destinationOut)
        }
        .compositingGroup()
    }
}

/// The bubble's one transition, both ways: out, the pull-out; in, the same path back while it shrinks and rises.
/// One on purpose. With two (`.asymmetric`, 0.13.3) SwiftUI kept both applied while the bubble rested, so its offset
/// counted twice: Glass bubbles sat twice as far out, and Black ones beyond the island's edge, unseen (your test,
/// 2026-10-01). Going in, the spring's overshoot happens inside the pill, where nothing shows.
struct PullOut: Transition {
    let tucked: CGFloat
    let settled: CGFloat
    let lift: CGFloat

    func body(content: Content, phase: TransitionPhase) -> some View {
        content.modifier(PullOutEffect(progress: phase.isIdentity ? 1 : 0, tucked: tucked, settled: settled,
                                       shrinks: phase == .didDisappear, lift: lift))
    }
}

/// A bubble on its way out from behind the pill: 0 tucked behind the pill's end, 1 settled beside it. It stretches
/// sideways on the way (up to 1.35×) and is round again when it settles; the spring may carry it a little past 1,
/// the overshoot. The stretch comes from the progress itself, so the whole motion is one animated number.
struct PullOutEffect: ViewModifier, Animatable {
    var progress: CGFloat
    let tucked: CGFloat
    let settled: CGFloat
    /// Going back in: it also shrinks (to 45%) and rises by `lift` as it tucks, so it ends wholly inside the pill.
    var shrinks = false
    var lift: CGFloat = 0

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = min(max(progress, 0), 1)
        let stretch = 1 + 0.35 * sin(.pi * p)
        let size = shrinks ? 0.45 + 0.55 * p : 1
        content
            .scaleEffect(x: stretch * size, y: size / stretch.squareRoot())
            .offset(x: tucked + (settled - tucked) * progress, y: shrinks ? -lift * (1 - p) : 0)
    }
}

/// Keep-awake is on: a coffee cup (decision 8), inside a draining ring when you chose a length (0.13.1).
struct KeepAwakeBubbleView: View {
    var store: KeepAwakeStore?
    var edgeToEdge = false

    var body: some View {
        ZStack {
            if edgeToEdge { Circle().fill(Color.black) }
            KeepAwakeRing(period: store?.period)
                .padding(store?.period != nil && !edgeToEdge ? 5 : 0)  // like the timer's ring
        }
        .accessibilityLabel(store?.status ?? "Keeping your Mac awake")
    }
}

/// A class starting within 10 minutes: a ring in its calendar's colour that empties as it gets closer, the minutes
/// left inside. Redraws every 5 s, only while it's on screen.
struct ClassBubbleView: View {
    let event: CalendarEvent
    var edgeToEdge = false

    var body: some View {
        let color = Color(event.color)
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let left = max(0, event.start.timeIntervalSince(context.date))
            ZStack {
                if edgeToEdge { Circle().fill(Color.black) }
                Circle().inset(by: 1.5).stroke(color.opacity(0.25), lineWidth: 3)
                Circle()
                    .inset(by: 1.5)
                    .trim(from: 0, to: min(1, left / SideRules.classWindow))
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int((left / 60).rounded(.up)))")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(color)
            }
            .padding(edgeToEdge ? 0 : 5)
        }
        .accessibilityLabel("\(event.title) starts \(CalendarRules.countdown(to: event.start, now: .now))")
    }
}

import Foundation
import Observation
import SwiftUI
import BrimCore

/// A timer that just ended, for "Time's up".
public struct EndedTimer: Equatable, Sendable {
    public var total: TimeInterval
    public var at: Date
    /// The Mac slept through it (or Brim wasn't running): the alert says "Ended at 15:05" (PRD F9).
    public var whileAway: Bool
    /// A Focus timer's "Time's up" offers a break.
    public var kind: TimerKind = .focus
}

/// "5 min left" for which timer.
public struct TimerMilestone: Equatable, Sendable {
    public var kind: TimerKind
    public var minutes: Int
}

/// The timers (F9, decision 7): up to five at once, started from the Timers tab (Focus | Break, the ruler) or the
/// pill's right-click menu. The one that ends first rides beside the music pill as a ring (or is the pill when
/// no music rests). "5 min left" / "1 min left" per timer, and "Time's up" with sound and a notification, which
/// offers a break after Focus. Stored as end times, so they survive sleep and relaunch. One sleep until the
/// next moment any timer needs; never a repeating timer.
@Observable
public final class TimerStore {
    /// In the order you started them.
    public private(set) var items: [TimerItem] = []
    /// The latest "N min left", for its notice.
    public private(set) var milestone: TimerMilestone?
    public private(set) var ended: EndedTimer?
    /// "Time's up" is sounding: opening the island counts as seeing it, and stops it.
    public private(set) var ringing = false
    /// The Timers tab's picker: Focus or Break (switching moves the ruler to its usual length)…
    public var mode: TimerKind = .focus {
        didSet { if mode != oldValue { pickedMinutes = mode.defaultMinutes } }
    }
    /// …and the length on the ruler, in minutes.
    public var pickedMinutes = TimerKind.focus.defaultMinutes
    /// Each end and how late it fired (release goal: within 1 s). The health log keeps these.
    @ObservationIgnored public var onEnd: ((_ lateBy: TimeInterval) -> Void)?
    /// Focus history (feature 3): the label for the next Focus timer, and where finished or stopped ones go.
    @ObservationIgnored public var history: FocusHistoryStore?

    @ObservationIgnored private let island: IslandCoordinator
    @ObservationIgnored private let alarm: any TimerAlarm
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var wake: Task<Void, Never>?
    /// Tests set the clock by hand.
    @ObservationIgnored var now: () -> Date = Date.init

    public init(island: IslandCoordinator, alarm: any TimerAlarm, defaults: UserDefaults = .standard) {
        self.island = island
        self.alarm = alarm
        self.defaults = defaults
    }

    /// The timer the pill and its ring show: the running one that ends first.
    public var soonest: TimerItem? { TimerRules.soonest(items, at: now()) }
    public var state: TimerState? { soonest?.state }
    /// The ring rests beside the music pill while any timer exists (a swipe hides everything resting).
    public var bubbleVisible: Bool { !items.isEmpty }
    public var canStartAnother: Bool { items.count < TimerRules.maximumTimers }

    /// Picks up timers saved before a relaunch (and the single timer of Brim 0.12 and older); ones that ended
    /// meanwhile say "Ended at …". Notices that passed while Brim was away aren't replayed.
    public func start() {
        if let data = defaults.data(forKey: Key.items), let saved = try? JSONDecoder().decode([TimerItem].self, from: data) {
            items = saved
        } else if let data = defaults.data(forKey: Key.legacyState),
                  let old = try? JSONDecoder().decode(TimerState.self, from: data) {
            items = [TimerItem(kind: .focus, state: old)]
            defaults.removeObject(forKey: Key.legacyState)
        }
        let current = now()
        for index in items.indices {
            let left = items[index].state.remaining(at: current)
            items[index].shownMilestones.formUnion(TimerRules.milestones.filter { left <= TimeInterval($0 * 60) })
        }
        save()
        plan()
    }

    public func start(minutes: Int) {
        start(length: TimeInterval(minutes * 60))
    }

    /// The Timers tab's Start: the ruler's length, Focus or Break.
    public func startPicked() {
        start(length: TimeInterval(pickedMinutes * 60), kind: mode)
    }

    /// Any length (the debug check uses 100 s). Nothing happens at the limit of five.
    public func start(length: TimeInterval, kind: TimerKind = .focus) {
        Usage.note("timer.start.\(kind.rawValue)")
        guard canStartAnother else { return }
        alarm.prepare()
        stopAlarm()
        items.append(TimerItem(kind: kind, state: .start(length: length, at: now()), startedAt: now(),
                               label: kind == .focus ? history?.selectedLabel : nil))
        save()
        plan()
    }

    /// "Time's up" after a Focus timer offers this: a 5-minute break.
    public func startBreak() {
        stopAlarm()
        start(length: TimeInterval(TimerKind.rest.defaultMinutes * 60), kind: .rest)
    }

    /// Back to work after a break: a Focus timer of the usual length (your pick, 2026-10-01).
    public func startFocus() {
        stopAlarm()
        start(length: TimeInterval(TimerKind.focus.defaultMinutes * 60), kind: .focus)
    }

    /// What Time's up offers next: a Break after Focus, Focus after a Break. One click either way.
    public func startNext() {
        Usage.note("timer.next")
        switch ended?.kind {
        case .focus?: startBreak()
        case .rest?: startFocus()
        case nil: stopAlarm()
        }
    }

    public func pause(_ id: UUID) { update(id) { $0.state = $0.state.paused(at: now()) } }
    public func resume(_ id: UUID) { update(id) { $0.state = $0.state.resumed(at: now()) } }
    public func addMinute(_ id: UUID) { update(id) { $0.state = $0.state.addingMinute() } }

    public func cancel(_ id: UUID) {
        if let item = items.first(where: { $0.id == id }) { record(item, finished: false, at: now()) }
        items.removeAll { $0.id == id }
        save()
        plan()
    }

    public func cancelAll() {
        for item in items { record(item, finished: false, at: now()) }
        items = []
        save()
        plan()
    }

    /// Stop on "Time's up": silence, and the alert goes.
    public func stopAlarm() {
        ringing = false
        alarm.silence()
        island.dismiss(.timerDone)
    }

    private func update(_ id: UUID, _ change: (inout TimerItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        save()
        plan()
    }

    /// Finishes whatever ended, then plans the one wake-up: the next notice or end of any timer.
    private func plan() {
        wake?.cancel()
        let current = now()
        let finished = items.filter { $0.state.hasEnded(at: current) }
            .sorted { ($0.state.endsAt ?? current) < ($1.state.endsAt ?? current) }
        for item in finished {
            finish(item, lateBy: current.timeIntervalSince(item.state.endsAt ?? current))
        }
        tellIsland()
        guard let next = TimerRules.nextEvent(in: items, at: current) else { return }
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.at.timeIntervalSince(current))), tolerance: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.wakeUp(for: next)
        }
    }

    private func wakeUp(for next: (id: UUID, milestone: Int?, at: Date)) {
        if let minutes = next.milestone, next.at <= now().addingTimeInterval(0.5),
           let index = items.firstIndex(where: { $0.id == next.id }), !items[index].state.hasEnded(at: now()) {
            items[index].shownMilestones.insert(minutes)
            milestone = TimerMilestone(kind: items[index].kind, minutes: minutes)
            island.post(.timerNotice(at: now()))
            save()
        }
        plan()
    }

    private func finish(_ item: TimerItem, lateBy: TimeInterval) {
        let endedAt = item.state.endsAt ?? now()
        let away = lateBy > 60
        ended = EndedTimer(total: item.state.total, at: endedAt, whileAway: away, kind: item.kind)
        // "Time's up" first, so the island goes straight from the timer to the alert. The other order left it
        // hidden for 2 ms, and the spring made it start to vanish and pop back (your test, 16:15:13).
        island.post(.timerDone(at: now()))
        ringing = true
        record(item, finished: true, at: endedAt)
        items.removeAll { $0.id == item.id }
        save()
        tellIsland()
        let time = endedAt.formatted(date: .omitted, time: .shortened)
        let what = "\(item.kind.title) timer (\(item.state.lengthText))"
        alarm.ring(title: "Time's up", body: away ? "Your \(what) ended at \(time)." : "Your \(what) is done.")
        onEnd?(lateBy)
    }

    /// A Focus timer that ran a minute or more goes into Focus history; breaks don't.
    private func record(_ item: TimerItem, finished: Bool, at end: Date) {
        guard let session = FocusHistory.session(for: item, endedAt: end, finished: finished) else { return }
        history?.record(session)
    }

    /// The island needs to know whether any timer runs (the ring) and whether you're focusing (decision 11).
    private func tellIsland() {
        island.setTimerRunning(!items.isEmpty)
        island.setFocusing(TimerRules.isFocusing(items))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items), !items.isEmpty {
            defaults.set(data, forKey: Key.items)
        } else {
            defaults.removeObject(forKey: Key.items)
        }
    }

    private enum Key {
        static let items = "timer.items"
        /// Brim 0.12 and older kept one timer.
        static let legacyState = "timer.state"
    }
}

private let timerOrange = Color.orange

/// The ring bubble beside the music pill (your pick A): an orange ring that empties, minutes inside.
/// Redraws every 5 s (every second in the last minute), and only while it's on screen.
/// The ring's look, fed plain values: the side bubble shows it from `TimerStore`, the welcome with an example.
struct TimerRing: View {
    let share: Double
    let label: String
    var paused = false
    var edgeToEdge = false

    var body: some View {
        ZStack {
            if edgeToEdge { Circle().fill(Color.black) }
            Circle().inset(by: 1.5).stroke(timerOrange.opacity(0.25), lineWidth: 3)
            Circle()
                .inset(by: 1.5)
                .trim(from: 0, to: share)
                .stroke(timerOrange, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label)
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(timerOrange)
                .minimumScaleFactor(0.7)
        }
        .padding(edgeToEdge ? 0 : 5)
        .opacity(paused ? 0.5 : 1)
    }
}

struct TimerBubbleView: View {
    let timer: TimerStore
    /// Which timer; the one that ends first when nil.
    var itemID: UUID?
    /// Black: the ring sits on the circle's very edge, on black, with no rim around it (your note, 2026-09-30).
    var edgeToEdge = false

    var body: some View {
        if let state = (itemID.flatMap { id in timer.items.first { $0.id == id } } ?? timer.soonest)?.state {
            let lastMinute = state.remaining(at: .now) < 65
            TimelineView(.periodic(from: .now, by: lastMinute ? 1 : 5)) { context in
                TimerRing(share: state.share(at: context.date), label: TimerRules.bubbleLabel(state.remaining(at: context.date)),
                          paused: state.isPaused, edgeToEdge: edgeToEdge)
            }
            .accessibilityLabel("Timer: \(TimerRules.clock(state.remaining(at: .now))) left")
        }
    }
}

/// The timer on its own, same size as the music pill: icon and time left.
struct TimerPillView: View {
    let timer: TimerStore

    var body: some View {
        if let state = timer.state {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 6) {
                    Image(systemName: state.isPaused ? "pause.fill" : "timer")
                        .font(.system(size: 13, weight: .semibold))
                    Text(TimerRules.clock(state.remaining(at: context.date)))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(timerOrange)
                .opacity(state.isPaused ? 0.6 : 1)
            }
        }
    }
}

/// "5 min left · Focus", 3 s.
struct TimerNoticeView: View {
    let timer: TimerStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer").font(.system(size: 13, weight: .semibold)).foregroundStyle(timerOrange)
            Text("\(timer.milestone?.minutes ?? 1) min left").font(.system(size: 13, weight: .semibold))
            Spacer()
            if let milestone = timer.milestone {
                Text(milestone.kind.title).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
    }
}

/// "Time's up · Focus" with Break (after Focus) and Stop; "Ended at 15:05" if the Mac slept through it.
/// On the pill the window handles the clicks (the pill passes clicks through to your apps): the Stop end stops
/// it, the Break before it starts a break, anywhere else stops it. Inside the open island the buttons are live.
struct TimerDoneView: View {
    let timer: TimerStore
    /// Break after Focus, Focus after a Break (`TimerStore.startNext`).
    var onNext: (() -> Void)?
    var onStop: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer").font(.system(size: 13, weight: .semibold)).foregroundStyle(timerOrange)
            if let ended = timer.ended, ended.whileAway {
                Text("Ended at \(ended.at, format: .dateTime.hour().minute())").font(.system(size: 13, weight: .semibold))
            } else {
                Text("Time's up").font(.system(size: 13, weight: .semibold))
                if let ended = timer.ended {
                    Text("· \(ended.kind.title)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch timer.ended?.kind {
            case .focus?: capsule("Break", filled: false, action: onNext)
            case .rest?: capsule("Focus", filled: false, action: onNext)  // one click back to work (2026-10-01)
            case nil: EmptyView()
            }
            capsule("Stop", filled: true, action: onStop)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func capsule(_ title: String, filled: Bool, action: (() -> Void)?) -> some View {
        let label = Text(title)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(filled ? timerOrange : Color.primary.opacity(0.14), in: Capsule())
            .foregroundStyle(filled ? Color.white : Color.primary)
        if let action {
            Button(action: action) { label }.buttonStyle(.plain)
        } else {
            label
        }
    }
}

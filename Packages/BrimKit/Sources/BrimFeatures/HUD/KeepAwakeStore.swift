import Foundation
import Observation
import SwiftUI
import BrimCore

/// Keep-awake (F11): on from the coffee in the open island's tab row or the right-click menu, for 10 min, 30 min,
/// 1 hour, 2 hours, or until you stop it (your fix round, 2026-09-30). A coffee bubble on the pill's left while it's
/// on (or a small coffee pill when nothing else rests), with a ring that drains when it has a length. Off again when
/// its length runs out, when you turn it off, or when Brim quits: it isn't remembered across launches, so the Mac can
/// never be left awake by surprise.
@Observable
public final class KeepAwakeStore {
    /// A length you chose: when it started and when it turns itself off.
    public struct Period: Equatable, Sendable {
        public let since: Date
        public let until: Date
    }

    public private(set) var isOn = false
    /// Nil while it's on "until I stop it" (and while it's off).
    public private(set) var period: Period?
    @ObservationIgnored private let service: any KeepAwakeService
    @ObservationIgnored private let island: IslandCoordinator
    @ObservationIgnored private var ending: Task<Void, Never>?
    /// Injectable so tests control time.
    @ObservationIgnored var now: () -> Date = Date.init

    public init(service: any KeepAwakeService, island: IslandCoordinator) {
        self.service = service
        self.island = island
    }

    /// Keeps the Mac awake for `minutes`, or until you stop it (nil). Choosing again while it's on starts over.
    public func start(minutes: Int?) {
        Usage.note("keepAwake.start")
        start(length: minutes.map { TimeInterval($0) * 60 })
        Log.app.notice("Keep-awake on: \(minutes ?? 0, privacy: .public) min (0: until stopped)")
    }

    /// Internal so tests can use lengths in seconds.
    func start(length: TimeInterval?) {
        if !isOn {
            guard service.setAwake(true) else { return }  // macOS said no: never claim the Mac is kept awake
            isOn = true
            island.setKeepAwake(true)
        }
        let start = now()
        period = length.map { Period(since: start, until: start.addingTimeInterval($0)) }
        scheduleEnd()
    }

    public func stop() {
        guard isOn else { return }
        ending?.cancel()
        ending = nil
        isOn = !service.setAwake(false)
        if !isOn { period = nil }
        island.setKeepAwake(isOn)
    }

    /// The plain switch (the debug check): on until you stop it, or off.
    public func set(_ on: Bool) {
        if on {
            if !isOn { start(minutes: nil) }
        } else {
            stop()
        }
    }

    /// For hover and VoiceOver: "Keeping your Mac awake until 15:45", or "… until you stop it".
    public var status: String {
        guard isOn else { return "Keep your Mac awake" }
        guard let period else { return "Keeping your Mac awake until you stop it" }
        return "Keeping your Mac awake until \(period.until.formatted(date: .omitted, time: .shortened))"
    }

    /// One wake-up at the end, never a repeating timer. `Task.sleep` counts on the continuous clock, which keeps
    /// going while the Mac sleeps, so a length that ran out during sleep ends as soon as the Mac wakes.
    private func scheduleEnd() {
        ending?.cancel()
        ending = nil
        guard let period else { return }
        let wait = max(0, period.until.timeIntervalSince(now()))
        ending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.ending = nil
            self.stop()
            Log.app.notice("Keep-awake off: its length ran out")
        }
    }
}

/// The coffee cup, with a ring that drains while a length runs (none for "until I stop it"). Redraws every 5 s,
/// only while it's on screen.
struct KeepAwakeRing: View {
    let period: KeepAwakeStore.Period?
    /// The cup alone, without a ring.
    var cupSize: CGFloat = 13

    var body: some View {
        if let period {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                ZStack {
                    Circle().inset(by: 1.5).stroke(Color.orange.opacity(0.25), lineWidth: 3)
                    Circle()
                        .inset(by: 1.5)
                        .trim(from: 0, to: KeepAwakeRules.share(since: period.since, until: period.until, at: context.date))
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    cup(size: cupSize - 3)
                }
            }
        } else {
            cup(size: cupSize)
        }
    }

    private func cup(size: CGFloat) -> some View {
        Image(systemName: "cup.and.saucer.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.orange)
    }
}

/// The small coffee pill when keep-awake is the only thing resting.
struct KeepAwakePillView: View {
    var store: KeepAwakeStore?

    var body: some View {
        KeepAwakeRing(period: store?.period, cupSize: 14)
            .frame(width: 26, height: 26)
            .accessibilityLabel(store?.status ?? "Keeping your Mac awake")
    }
}

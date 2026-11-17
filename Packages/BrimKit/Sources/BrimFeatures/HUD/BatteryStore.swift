import Observation
import SwiftUI
import BrimCore

/// The Mac's battery for the island (P-4, PRD F10): a 3 s notice when you plug in (charging or not),
/// when it's full, and when Low Power Mode turns on or off. Quiet at launch; event-driven.
@Observable
public final class BatteryStore {
    public private(set) var state: BatteryState?
    public private(set) var notice: BatteryNotice?
    /// Counts notices, so the icon's bounce plays again for each one.
    public private(set) var noticeCount = 0
    /// Settings → Notices → Battery.
    @ObservationIgnored public var enabled = true

    @ObservationIgnored private let service: any BatteryService
    @ObservationIgnored private let island: IslandCoordinator
    @ObservationIgnored private var listener: Task<Void, Never>?

    public init(service: any BatteryService, island: IslandCoordinator) {
        self.service = service
        self.island = island
    }

    public func start() {
        guard listener == nil else { return }
        let states = service.states
        listener = Task { [weak self] in
            for await state in states { self?.handle(state) }
        }
        service.start()
    }

    /// Internal so tests can feed readings directly.
    func handle(_ next: BatteryState) {
        let previous = state
        state = next
        guard enabled, let notice = BatteryNotice.notice(from: previous, to: next) else { return }
        if case .pluggedIn = notice {
            if let words = PlugInRules.notice(for: next) { show(words) }  // at once: "Charging" or "Plugged In"
        } else {
            show(notice)
        }
    }

    private func show(_ notice: BatteryNotice) {
        self.notice = notice
        noticeCount += 1
        island.post(.battery(at: .now))
    }
}

/// The notice in the island, iPhone-style: what happened on the left, the level on the right.
struct BatteryNoticeView: View {
    let store: BatteryStore

    var body: some View {
        let notice = store.notice
        // Pill-sized, like the volume HUD (your report, 2026-10-29): the symbol says what happened (bolt: charging,
        // plug: paused, check: full; Low Power Mode: the battery's colour), the words are for VoiceOver.
        HStack(spacing: 6) {
            if let symbol = Self.leadingSymbol(notice) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Spacer(minLength: 4)
            if let state = store.state {
                Text("\(Int((state.level * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                Image(systemName: state.symbolName(charging: notice == .pluggedIn(charging: true) || state.power == .charging))
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(tint)
                    .symbolEffect(.bounce, value: store.noticeCount)  // plays once per notice, then idles
            }
        }
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notice?.title ?? "Battery")
    }

    private var tint: Color {
        switch store.notice {
        case .pluggedIn(true)?, .fullyCharged?: .green
        case .lowPowerMode(true)?: .yellow
        default: .primary
        }
    }

    static func leadingSymbol(_ notice: BatteryNotice?) -> String? {
        switch notice {
        case .pluggedIn(true)?: "bolt.fill"
        case .pluggedIn(false)?: "powerplug.fill"
        case .fullyCharged?: "checkmark.circle.fill"
        case .lowPowerMode?, nil: nil
        }
    }
}

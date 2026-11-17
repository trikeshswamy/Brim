import Observation
import SwiftUI
import BrimCore

/// Headphones connecting (P-4, PRD F7): a 3 s notice with left, right and case battery, like the iPhone's.
@Observable
public final class HeadphonesStore {
    public private(set) var battery: HeadphonesBattery?
    /// The notice says "Disconnected" instead of levels.
    public private(set) var disconnected = false
    /// Shown under the switch in Settings → Notices when it isn't `.ready`.
    public private(set) var availability: Availability = .starting
    /// Settings → Notices → AirPods and headphones.
    @ObservationIgnored public var enabled = true
    /// Every connection and whether the notice showed: the health log keeps these.
    @ObservationIgnored public var onConnection: ((HeadphonesConnection, _ shown: Bool) -> Void)?

    /// When each device (by name) last showed a notice: the next one within half an hour stays quiet.
    @ObservationIgnored private var lastShown: [String: Date] = [:]
    /// The clock (tests move it).
    @ObservationIgnored var now: () -> Date = Date.init

    @ObservationIgnored private let service: any HeadphonesService
    @ObservationIgnored private let island: IslandCoordinator
    @ObservationIgnored private var listener: Task<Void, Never>?

    public init(service: any HeadphonesService, island: IslandCoordinator) {
        self.service = service
        self.island = island
    }

    public func start() {
        guard listener == nil else { return }
        let connections = service.connections
        listener = Task { [weak self] in
            for await connection in connections { self?.handle(connection) }
        }
        service.start()
        refreshAvailability()
    }

    /// Settings calls this as the Notices page opens: permission can change in System Settings meanwhile.
    public func refreshAvailability() {
        availability = service.availability
        if enabled, availability == .ready { service.start() }
    }

    /// Settings → Permissions → Grant Access. This is the only path that may start a first-time Bluetooth prompt.
    public func requestPermission() {
        service.requestAccess()
        refreshAvailability()
    }

    /// Internal so tests can feed connections directly.
    func handle(_ connection: HeadphonesConnection) {
        if connection.levelsLate {
            // The levels of the notice just shown: fill them in while it's up; never a second notice.
            if enabled, !disconnected, island.hasGlance(.headphones) { battery = connection.battery }
            return
        }
        let device = connection.battery.name ?? ""
        let date = now()
        let recent = !HeadphonesNoticeRules.shows(after: lastShown[device], at: date)
        let show = enabled && !connection.wasConnectedAtStart && !recent
        if show {
            lastShown[device] = date
            battery = connection.battery
            disconnected = connection.disconnected
            island.post(.headphones(at: date, disconnected: connection.disconnected))
        } else if recent, enabled {
            let minutes = Int(date.timeIntervalSince(lastShown[device] ?? date) / 60)
            Log.devices.notice("Notice skipped: the same headphones showed one \(minutes, privacy: .public) min ago")
        }
        onConnection?(connection, show)
    }
}

/// The notice's look, fed plain values: the island shows it from `HeadphonesStore`, the welcome with an example.
struct HeadphonesNoticeContent: View {
    let battery: HeadphonesBattery
    let disconnected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: battery.symbolName)
                .font(.system(size: 14, weight: .semibold))
            Text(battery.name.map(HeadphonesNoticeView.shortName) ?? "Headphones")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 6)
            HStack(spacing: 8) {
                if disconnected || !battery.hasLevels {
                    Text(disconnected ? "Disconnected" : "Connected")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                } else {
                    ForEach(HeadphonesNoticeView.parts(of: battery), id: \.label) { part in
                        HStack(spacing: 3) {
                            Text(part.label).foregroundStyle(.secondary)
                            Text(part.level.map { "\($0)%" } ?? "—").monospacedDigit()
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle((part.level ?? 100) < 20 ? Color.red : Color.primary)  // PRD F7: under 20%
                        .fixedSize()  // levels never wrap; only the name shortens
                    }
                }
            }
            // Levels that come after the notice (0.14.1) fade in over "Connected"; only this part animates.
            .animation(.easeInOut(duration: 0.2), value: battery.hasLevels)
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }
}

/// The notice: the headphones' own symbol and name, then each part's level (your pick A: letters),
/// "Connected" when they report none, or "Disconnected".
struct HeadphonesNoticeView: View {
    let store: HeadphonesStore

    var body: some View {
        if let battery = store.battery {
            HeadphonesNoticeContent(battery: battery, disconnected: store.disconnected)
        }
    }

    /// "Sam’s AirPods Pro" → "AirPods Pro": the owner's name doesn't fit a 280 pt notice.
    static func shortName(_ name: String) -> String {
        if let range = name.range(of: "’s ") ?? name.range(of: "'s ") { return String(name[range.upperBound...]) }
        return name
    }

    /// Earbuds always show L, R and Case, with "—" for a part that isn't reporting (PRD F7), e.g. a case
    /// that's closed and away. One-piece headphones show their one level.
    static func parts(of battery: HeadphonesBattery) -> [(label: String, level: Int?)] {
        if let single = battery.single, battery.left == nil, battery.right == nil { return [("", single)] }
        return [("L", battery.left), ("R", battery.right), ("Case", battery.caseLevel)]
    }
}

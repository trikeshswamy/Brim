import Foundation

/// The Mac's battery as the island reads it (P-4, PRD F10). Brightness-style symbols live in the view.
public struct BatteryState: Equatable, Sendable {
    public enum Power: Equatable, Sendable {
        /// Running on battery.
        case battery
        case charging
        /// Plugged in but holding (Optimized Battery Charging, a charge limit): read on your Mac 2026-09-30.
        case notCharging
        /// Plugged in and full.
        case charged
    }

    /// 0 … 1
    public var level: Double
    public var power: Power
    public var lowPowerMode: Bool

    public init(level: Double, power: Power, lowPowerMode: Bool) {
        self.level = level
        self.power = power
        self.lowPowerMode = lowPowerMode
    }

    public var isPluggedIn: Bool { power != .battery }

    /// From IOKit's power-source keys: "Power Source State", "Is Charging", "Is Charged", capacities, "LPM Active".
    public static func from(state: String?, isCharging: Bool, isCharged: Bool, current: Double, max: Double,
                            lowPowerMode: Bool) -> BatteryState {
        let level = max > 0 ? min(Swift.max(current / max, 0), 1) : 0
        let power: Power = state != "AC Power" ? .battery : isCharged ? .charged : isCharging ? .charging : .notCharging
        return BatteryState(level: level, power: power, lowPowerMode: lowPowerMode)
    }

    /// iPhone-style battery symbol for the level (a bolt while charging).
    public var symbolName: String { symbolName(charging: power == .charging) }

    /// The same, with the bolt when the notice says "Charging" (macOS's own flag can lag it, see `PlugInRules`).
    public func symbolName(charging: Bool) -> String {
        let steps = [0, 25, 50, 75, 100]
        let step = steps.min { abs(Double($0) / 100 - level) < abs(Double($1) / 100 - level) } ?? 100
        return "battery.\(step)percent" + (charging ? ".bolt" : "")
    }
}

/// A short island notice worth your attention (PRD F10). Plugging in, reaching full, Low Power Mode.
public enum BatteryNotice: Equatable, Sendable {
    case pluggedIn(charging: Bool)
    case fullyCharged
    case lowPowerMode(on: Bool)

    /// Compares two readings; the first reading at launch is quiet. Plugging in wins over the rest (its words:
    /// `PlugInRules`).
    public static func notice(from old: BatteryState?, to new: BatteryState) -> BatteryNotice? {
        guard let old else { return nil }
        if !old.isPluggedIn, new.isPluggedIn { return .pluggedIn(charging: new.power == .charging) }
        if old.lowPowerMode != new.lowPowerMode { return .lowPowerMode(on: new.lowPowerMode) }
        if old.power != .charged, new.power == .charged { return .fullyCharged }
        return nil
    }

    public var title: String {
        switch self {
        // From 80% up macOS may be charging or holding, and can't say which in the first seconds (`PlugInRules`).
        case .pluggedIn(let charging): charging ? "Charging" : "Plugged In"
        case .fullyCharged: "Fully Charged"
        case .lowPowerMode(let on): on ? "Low Power Mode On" : "Low Power Mode Off"
        }
    }
}

/// What plugging in says, at once (your reports, 2026-10-02 to -05: "Charging Paused" while charging at 65, 67, 83
/// and 89%).
///
/// macOS's public charging flag ("Is Charging") turns on 3–10 s after plugging in: all 4 of your plug-ins during the
/// 3-day check (48, 69, 83, 89%) read off at 3 s and on at 10 s. At your 90% limit it stays off. So in the first
/// seconds charging and holding look the same. Below 80% macOS never holds the charge: "Charging". From 80% up:
/// "Plugged In", which is always true.
public enum PlugInRules {
    /// Below this macOS doesn't hold the charge (Optimized Battery Charging and charge limits start at 80%).
    public static let holdsFrom = 0.8

    public static func notice(for state: BatteryState) -> BatteryNotice? {
        switch state.power {
        case .battery: return nil  // unplugged again: nothing to say
        case .charged: return .fullyCharged
        case .charging: return .pluggedIn(charging: true)  // the flag only turns on while charging
        case .notCharging: return .pluggedIn(charging: state.level < holdsFrom)  // lagging below 80%; unknown above
        }
    }
}

/// Reports the battery. Live: IOKit power-source notifications + Low Power Mode changes; tests: a fake.
@MainActor
public protocol BatteryService: AnyObject {
    var states: AsyncStream<BatteryState> { get }
    func start()
}

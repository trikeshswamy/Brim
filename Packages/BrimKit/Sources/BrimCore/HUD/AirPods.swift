import Foundation

/// Connected AirPods' (or other headphones') battery for the island (P-4). Read through IOBluetooth's
/// battery calls, which work on macOS 27 (checked 2026-09-30: left 100, right 100, case 88).
public struct HeadphonesBattery: Equatable, Sendable {
    /// Nil when there's no usable name and no known product (see `DeviceNames`).
    public var name: String?
    /// 0 … 100; nil when that part doesn't report (a closed or far case, one-piece headphones).
    public var left: Int?
    public var right: Int?
    public var caseLevel: Int?
    /// One-piece headphones (AirPods Max, Beats).
    public var single: Int?

    public init(name: String? = nil, left: Int? = nil, right: Int? = nil, caseLevel: Int? = nil, single: Int? = nil) {
        self.name = name
        self.left = left
        self.right = right
        self.caseLevel = caseLevel
        self.single = single
    }

    /// IOBluetooth reports 0 for parts it doesn't know; those become nil. Nil overall: nothing to show.
    public static func from(name: String?, left: Int, right: Int, caseLevel: Int, single: Int) -> HeadphonesBattery? {
        func known(_ value: Int) -> Int? { (1...100).contains(value) ? value : nil }
        let battery = HeadphonesBattery(name: DeviceNames.usable(name), left: known(left), right: known(right),
                                        caseLevel: known(caseLevel), single: known(single))
        return battery.left == nil && battery.right == nil && battery.caseLevel == nil && battery.single == nil ? nil : battery
    }

    public var hasLevels: Bool { left != nil || right != nil || caseLevel != nil || single != nil }

    public var symbolName: String {
        let name = name ?? ""
        if name.localizedCaseInsensitiveContains("max") { return "airpodsmax" }
        if name.localizedCaseInsensitiveContains("pro") { return "airpodspro" }
        if name.localizedCaseInsensitiveContains("airpods") { return "airpods" }
        // No name: earbuds (left/right or a case) look like AirPods; one-piece ones like headphones.
        return left != nil || right != nil || caseLevel != nil ? "airpods" : "headphones"
    }
}

/// One connection or disconnection as the service saw it.
public struct HeadphonesConnection: Equatable, Sendable {
    /// No levels when the device never reported any (or it just disconnected).
    public var battery: HeadphonesBattery
    /// Already connected when Brim started (macOS reports those as Brim starts listening): not news, so no notice.
    public var wasConnectedAtStart: Bool
    public var disconnected: Bool
    /// The levels of a connection already shown, arriving after it: they fill in the notice while it shows, never a
    /// second notice (0.14.1).
    public var levelsLate: Bool

    public init(battery: HeadphonesBattery, wasConnectedAtStart: Bool = false, disconnected: Bool = false,
                levelsLate: Bool = false) {
        self.battery = battery
        self.wasConnectedAtStart = wasConnectedAtStart
        self.disconnected = disconnected
        self.levelsLate = levelsLate
    }
}

/// macOS 27 announced one AirPods reconnection twice, 0.8 s apart (2026-09-30), and the notice showed twice.
/// A second connection within 15 s is the same one, unless a disconnection came between.
public struct ConnectionDeduper: Sendable {
    public static let window: TimeInterval = 15
    private var connectedAt: [String: Date] = [:]

    public init() {}

    public mutating func isNew(_ address: String, at date: Date) -> Bool {
        if let last = connectedAt[address], date.timeIntervalSince(last) < Self.window { return false }
        connectedAt[address] = date
        return true
    }

    public mutating func disconnected(_ address: String) {
        connectedAt[address] = nil
    }
}

/// One headphones notice per device per half hour (your 3-day check, 2026-10-05: earbuds that report no battery
/// announced a connection every 3–15 minutes, even at night, while staying connected: 88 connections against 4
/// disconnections, 93 notices in 1.5 days).
public enum HeadphonesNoticeRules {
    public static let quietPeriod: TimeInterval = 30 * 60

    /// Whether a connection or disconnection shows, given when the same device last showed a notice.
    public static func shows(after lastShown: Date?, at now: Date) -> Bool {
        guard let lastShown else { return true }
        return now.timeIntervalSince(lastShown) >= quietPeriod
    }
}

/// Headphones connecting, with their battery. Live: IOBluetooth connect notifications; tests: a fake.
@MainActor
public protocol HeadphonesService: AnyObject {
    var connections: AsyncStream<HeadphonesConnection> { get }
    /// Bluetooth permission, and whether macOS still reports AirPods battery (a private call).
    var availability: Availability { get }
    /// Explicitly begin the permission flow from Settings. Normal startup must use `start()` only.
    func requestAccess()
    func start()
}

public extension HeadphonesService {
    /// Fakes and older implementations do not need a separate permission path.
    func requestAccess() { start() }
}

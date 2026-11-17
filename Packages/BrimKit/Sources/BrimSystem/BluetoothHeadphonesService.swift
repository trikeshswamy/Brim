import CoreAudio
import CoreBluetooth
import Foundation
import IOBluetooth
import BrimCore

/// Reports headphones as they connect, with left/right/case battery, and as they disconnect (P-4).
///
/// - Connections: IOBluetooth's connect notification (needs the Bluetooth permission, asked once).
/// - Battery: the device's `batteryPercentLeft/Right/Case/Single` values. Not public API, but present and
///   working on macOS 27 (checked 2026-09-30); if a later macOS removes them, the notice just doesn't show.
/// - Name: the matching sound output's name (its ID carries the Bluetooth address), else IOBluetooth's, else
///   the Apple product ("AirPods Pro"): on macOS 27 your AirPods' name came back unusable from both.
public final class BluetoothHeadphonesService: NSObject, HeadphonesService {
    public let connections: AsyncStream<HeadphonesConnection>
    private let continuation: AsyncStream<HeadphonesConnection>.Continuation
    private var notification: IOBluetoothUserNotification?
    private var startedAt = Date.distantPast
    private var connectedAtStart: Set<String> = []
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    /// Each device's name from its connection, for its disconnect notice (the sound output is gone by then).
    private var names: [String: String] = [:]
    private var deduper = ConnectionDeduper()

    public override init() {
        (connections, continuation) = AsyncStream.makeStream(of: HeadphonesConnection.self)
        super.init()
    }

    /// You already allowed Bluetooth: AirPods notices may start on without asking (read without prompting).
    public static var isAuthorized: Bool { CBManager.authorization == .allowedAlways }

    public var availability: Availability {
        switch CBManager.authorization {
        case .denied, .restricted: return .needsPermission
        case .notDetermined: return .starting  // macOS is asking you right now
        default: break
        }
        guard IOBluetoothDevice.instancesRespond(to: NSSelectorFromString("batteryPercentLeft")) else {
            return .unavailable(reason: "This version of macOS doesn't share AirPods battery with apps.")
        }
        return .ready
    }

    public func start() {
        start(requestingAccess: false)
    }

    /// Called only by the explicit Grant Access action in Settings. Keeping this separate prevents a saved
    /// "AirPods and headphones" setting from opening a permission prompt on every launch.
    public func requestAccess() {
        start(requestingAccess: true)
    }

    private func start(requestingAccess: Bool) {
        guard notification == nil else { return }
        guard CBManager.authorization == .allowedAlways || (requestingAccess && CBManager.authorization == .notDetermined) else {
            Log.devices.notice("Bluetooth monitoring deferred until explicit permission request")
            return
        }
        startedAt = Date()
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let connected = paired.filter { $0.isConnected() }
        connectedAtStart = Set(connected.map { BluetoothNames.hex($0.addressString) })
        for device in connected where Self.isSound(device) { watchDisconnect(device) }
        notification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
        Log.devices.notice("Listening; \(connected.count) connected at start")
    }

    /// macOS 27 calls this on IOBluetooth's own background queue for new connections, and on the main thread
    /// for the ones it reports as Brim starts listening. It crashed Brim on 2026-09-30: Swift checks at run time
    /// that main-thread code really runs there. So both callbacks only hand the work to the main thread.
    @objc nonisolated private func connected(_ notification: IOBluetoothUserNotification?, device: IOBluetoothDevice) {
        nonisolated(unsafe) let device = device
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.handleConnect(device) }
        }
    }

    @objc nonisolated private func disconnected(_ notification: IOBluetoothUserNotification?, device: IOBluetoothDevice) {
        nonisolated(unsafe) let device = device
        nonisolated(unsafe) let notification = notification
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.handleDisconnect(notification, device: device) }
        }
    }

    private func handleConnect(_ device: IOBluetoothDevice) {
        // macOS also reports devices that were connected before Brim, right as it starts listening.
        // (Checked 2026-09-30: it does, for both devices connected then.)
        let old = connectedAtStart.contains(BluetoothNames.hex(device.addressString)) && Date().timeIntervalSince(startedAt) < 5
        // Sound devices only: a keyboard or mouse reporting its battery isn't this notice (PRD F7).
        guard Self.isSound(device) else {
            Log.devices.notice("Connected: not a sound device (class \(device.deviceClassMajor)), ignored")
            return
        }
        guard deduper.isNew(BluetoothNames.hex(device.addressString), at: Date()) else {
            Log.devices.notice("Connected again within 15 s: the same connection, ignored")
            return
        }
        Log.devices.notice("Connected: sound device, at start: \(old)")
        watchDisconnect(device)
        report(device, wasConnectedAtStart: old, attempt: 1, shown: false)
    }

    private func handleDisconnect(_ notification: IOBluetoothUserNotification?, device: IOBluetoothDevice) {
        let address = BluetoothNames.hex(device.addressString)
        notification?.unregister()
        disconnectNotifications[address] = nil
        deduper.disconnected(address)
        Log.devices.notice("Disconnected")
        let name = names[address] ?? Self.name(of: device)
        continuation.yield(HeadphonesConnection(battery: HeadphonesBattery(name: name), disconnected: true))
    }

    private func watchDisconnect(_ device: IOBluetoothDevice) {
        let address = BluetoothNames.hex(device.addressString)
        guard disconnectNotifications[address] == nil else { return }
        disconnectNotifications[address] = device.register(forDisconnectNotification: self,
                                                           selector: #selector(disconnected(_:device:)))
    }

    /// Shows the connection at once (0.5 s after macOS reports it), with its levels if they're there; levels that come
    /// later (AirPods: ~2 s) fill in the notice while it shows. It used to wait for the levels (every 2 s, up to 10 s):
    /// your other earbuds never report any while newly connected, so their notice came 10.5 s late (your check,
    /// 2026-10-01; seen in Brim's log).
    private func report(_ device: IOBluetoothDevice, wasConnectedAtStart: Bool, attempt: Int, shown: Bool) {
        let after = attempt == 1 ? 0.5 : 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard device.isConnected() else {
                    Log.devices.notice("Gone again before its battery arrived")
                    return
                }
                let name = Self.name(of: device)
                self.names[BluetoothNames.hex(device.addressString)] = name
                let elapsed = 0.5 + Double(attempt - 1)
                if let battery = Self.battery(of: device, name: name) {
                    Log.devices.notice("Battery after \(elapsed, format: .fixed(precision: 1)) s")
                    self.continuation.yield(HeadphonesConnection(battery: battery, wasConnectedAtStart: wasConnectedAtStart,
                                                                 levelsLate: shown))
                    return
                }
                if !shown {
                    // Now, without levels ("Connected"); they fill in if they come while the notice shows.
                    self.continuation.yield(HeadphonesConnection(battery: HeadphonesBattery(name: name),
                                                                 wasConnectedAtStart: wasConnectedAtStart))
                }
                if wasConnectedAtStart { return }  // no notice for those: nothing to fill in
                if attempt < 6 {
                    self.report(device, wasConnectedAtStart: wasConnectedAtStart, attempt: attempt + 1, shown: true)
                } else {
                    Log.devices.notice("No battery within 5.5 s")
                }
            }
        }
    }

    private static func isSound(_ device: IOBluetoothDevice) -> Bool {
        Int(device.deviceClassMajor) == Int(kBluetoothDeviceClassMajorAudio)
    }

    /// The sound output's name, else Bluetooth's, else the Apple product ("AirPods Pro").
    private static func name(of device: IOBluetoothDevice) -> String? {
        DeviceNames.usable(outputName(address: BluetoothNames.hex(device.addressString))) ?? DeviceNames.usable(device.name)
            ?? BluetoothNames.productName(of: device)
    }

    private static func battery(of device: IOBluetoothDevice, name: String?) -> HeadphonesBattery? {
        func level(_ key: String) -> Int {
            guard device.responds(to: NSSelectorFromString(key)) else { return 0 }
            return (device.value(forKey: key) as? NSNumber)?.intValue ?? 0
        }
        return HeadphonesBattery.from(name: name, left: level("batteryPercentLeft"), right: level("batteryPercentRight"),
                                      caseLevel: level("batteryPercentCase"), single: level("batteryPercentSingle"))
    }

    /// The sound output whose ID starts with this Bluetooth address ("XX-XX-XX-XX-XX-XX:output", checked 2026-09-30).
    private static func outputName(address: String) -> String? {
        guard !address.isEmpty else { return nil }
        var devices = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &devices, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devices, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            guard let uid = string(kAudioDevicePropertyDeviceUID, of: id),
                  BluetoothNames.hex(uid.split(separator: ":").first.map(String.init)) == address else { continue }
            return string(kAudioObjectPropertyName, of: id)
        }
        return nil
    }

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

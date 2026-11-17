import Foundation
import IOKit.ps
import BrimCore

/// The Mac's battery through IOKit (public API, no permission). Event-driven: macOS calls back when the
/// power source changes (plugged in, level, charging), and posts a notification for Low Power Mode.
public final class IOKitBatteryService: BatteryService {
    public let states: AsyncStream<BatteryState>
    private let continuation: AsyncStream<BatteryState>.Continuation
    private var source: CFRunLoopSource?
    private var lowPowerObserver: NSObjectProtocol?

    public init() {
        (states, continuation) = AsyncStream.makeStream(of: BatteryState.self)
    }

    public func start() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let service = Unmanaged<IOKitBatteryService>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { service.read() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            self.source = source
        }
        lowPowerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                                                                  object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        read()
    }

    private func read() {
        if let state = currentState() { continuation.yield(state) }
    }

    private func currentState() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            return BatteryState.from(
                state: description[kIOPSPowerSourceStateKey] as? String,
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isCharged: description[kIOPSIsChargedKey] as? Bool ?? false,
                current: (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 0,
                max: (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
        return nil
    }
}

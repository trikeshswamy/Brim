import AudioToolbox
import CoreAudio
import Foundation
import BrimCore

/// System output volume through CoreAudio (public API, no permission).
///
/// Event-driven: CoreAudio calls us when the volume, mute, or default output device changes.
/// Nothing polls. A new output device (e.g. AirPods connecting) is reported as a quiet `.baseline`
/// so the HUD doesn't pop up just because the device switched.
public final class CoreAudioVolumeService: VolumeService {
    public let events: AsyncStream<VolumeEvent>
    private let continuation: AsyncStream<VolumeEvent>.Continuation
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var lastState: VolumeState?

    /// The two device properties we watch: the overall volume and the mute switch.
    private static let watchedSelectors = [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute]

    public init() {
        (events, continuation) = AsyncStream.makeStream(of: VolumeEvent.self)
    }

    public func start() {
        guard systemListener == nil else { return }
        // Called by CoreAudio on the main queue whenever the default output device changes.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.bindDefaultDevice() }
        }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        systemListener = listener
        bindDefaultDevice()
    }

    /// Stop watching the old device, start watching the current default one, report it quietly.
    private func bindDefaultDevice() {
        unbindDevice()
        device = Self.defaultOutputDevice()
        guard device != kAudioObjectUnknown else { return }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.levelChanged() }
        }
        for selector in Self.watchedSelectors {
            var address = Self.address(selector, scope: kAudioDevicePropertyScopeOutput)
            if AudioObjectHasProperty(device, &address) {
                AudioObjectAddPropertyListenerBlock(device, &address, .main, listener)
            }
        }
        deviceListener = listener

        let state = readState()
        lastState = state
        continuation.yield(.baseline(state))
        Log.app.info("Volume: watching output device (adjustable: \(state.isAdjustable, privacy: .public))")
    }

    private func unbindDevice() {
        guard let listener = deviceListener, device != kAudioObjectUnknown else { return }
        for selector in Self.watchedSelectors {
            var address = Self.address(selector, scope: kAudioDevicePropertyScopeOutput)
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, listener)
        }
        deviceListener = nil
    }

    private func levelChanged() {
        let state = readState()
        guard state != lastState else { return }  // CoreAudio can repeat itself; only real changes count
        lastState = state
        continuation.yield(.changed(state))
    }

    // MARK: - Changing the volume (the key takeover)

    public func currentState() -> VolumeState? {
        guard device != kAudioObjectUnknown else { return nil }
        // Media-key callbacks must return quickly. The listener keeps this snapshot current, so
        // reading it here avoids re-querying the device name, transport, and model UID for every
        // press (held volume keys can arrive many times per second).
        return lastState ?? readState()
    }

    @discardableResult
    public func setLevel(_ level: Double) -> Bool {
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        var value = Float32(min(max(level, 0), 1))
        guard AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr else {
            return false
        }
        if let state = lastState {
            let updated = VolumeState(level: Double(value), isMuted: state.isMuted, deviceName: state.deviceName,
                                      output: state.output, isAdjustable: state.isAdjustable)
            lastState = updated
            continuation.yield(.changed(updated))
        }
        return true
    }

    @discardableResult
    public func setMuted(_ muted: Bool) -> Bool {
        var address = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value = UInt32(muted ? 1 : 0)
        guard AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr else {
            return false
        }
        if let state = lastState {
            let updated = VolumeState(level: state.level, isMuted: muted, deviceName: state.deviceName,
                                      output: state.output, isAdjustable: state.isAdjustable)
            lastState = updated
            continuation.yield(.changed(updated))
        }
        return true
    }

    // MARK: - Reading CoreAudio properties

    private func readState() -> VolumeState {
        var volumeAddress = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        var level = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let hasVolume = AudioObjectHasProperty(device, &volumeAddress)
            && AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &level) == noErr
        var settable: DarwinBoolean = false
        if hasVolume { AudioObjectIsPropertySettable(device, &volumeAddress, &settable) }

        var muteAddress = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var muted = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &muteAddress) {
            AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &muted)
        }

        return VolumeState(
            level: Double(level),
            isMuted: muted != 0,
            deviceName: Self.displayName(of: device),
            output: Self.outputKind(of: device),
            isAdjustable: hasVolume && settable.boolValue
        )
    }

    private static func defaultOutputDevice() -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    /// What the device is, for the HUD's icon (nil for the built-in speakers). Reads its transport type and model UID;
    /// no Bluetooth permission needed.
    private static func outputKind(of device: AudioObjectID) -> AudioOutputKind? {
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address(kAudioDevicePropertyTransportType)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return nil }
        let code = String(bytes: [24, 16, 8, 0].map { UInt8((transport >> $0) & 0xFF) }, encoding: .ascii) ?? ""
        var model: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address = Self.address(kAudioDevicePropertyModelUID)
        let modelUID = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &model) == noErr
            ? model?.takeRetainedValue() as String? : nil
        return AudioOutputKind.from(transport: code, modelUID: modelUID)
    }

    /// The device's name, or `nil` for the built-in speakers.
    private static func displayName(of device: AudioObjectID) -> String? {
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = address(kAudioDevicePropertyTransportType)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr,
           transport == kAudioDeviceTransportTypeBuiltIn {
            return nil
        }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address = Self.address(kAudioObjectPropertyName)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

import CoreAudio
import Foundation
import BrimCore

/// The sound outputs, through CoreAudio (public API, no permission). Switching sets the system's default
/// output, like Control Center (validated 2026-09-29: ~0.3 s each way). Event-driven: CoreAudio calls back
/// when devices come or go or the output changes.
public final class CoreAudioOutputsService: AudioOutputsService {
    public var onChange: (() -> Void)?
    private var listener: AudioObjectPropertyListenerBlock?

    public init() {}

    public func start() {
        guard listener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        self.listener = listener
    }

    public func outputs() -> [AudioOutput] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard Self.hasOutput(id) else { return nil }
            let transport = Self.transport(of: id)
            // Aggregate and virtual devices (Zoom, screen recorders) aren't places you'd send your music.
            guard transport != "grup", transport != "virt" else { return nil }
            let name = DeviceNames.usable(Self.name(of: id)) ?? Self.fallbackName(of: id, transport: transport)
            return AudioOutput(id: id, name: name, kind: AudioOutput.kind(transport: transport, name: name))
        }
    }

    public func currentOutput() -> AudioOutput.ID? {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    public func select(_ id: AudioOutput.ID) -> Bool {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioObjectID>.size), &value) == noErr
    }

    /// macOS 27 gave your AirPods' output the name "\u{2}" (2026-09-30): Bluetooth ones are named by product
    /// ("AirPods Pro"; the output's ID starts with the Bluetooth address), anything else plainly.
    private static func fallbackName(of id: AudioObjectID, transport: String) -> String {
        guard transport == "blue" || transport == "blea" else { return "Sound output" }
        var address = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid) == noErr, let uid,
           let product = BluetoothNames.productName(address: String((uid.takeRetainedValue() as String).prefix(17))) {
            return product
        }
        return "Bluetooth headphones"
    }

    private static func hasOutput(_ id: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        var size = UInt32(0)
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func name(of id: AudioObjectID) -> String? {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    /// The transport type's four letters, e.g. "blue" for Bluetooth.
    private static func transport(of id: AudioObjectID) -> String {
        var address = address(kAudioDevicePropertyTransportType)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return "" }
        let bytes = [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

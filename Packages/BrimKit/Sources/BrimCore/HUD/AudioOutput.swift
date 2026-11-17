import Foundation

/// A sound output macOS can play through (C1: your output picker, approved 2026-09-29).
public struct AudioOutput: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case builtInSpeakers, headphones, airPods, bluetooth, usb, display, airPlay, other
    }

    public var id: UInt32
    public var name: String
    public var kind: Kind

    public init(id: UInt32, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    /// The iPhone-style symbol for the list.
    public var symbolName: String {
        switch kind {
        case .builtInSpeakers: "laptopcomputer"
        case .headphones: "headphones"
        case .airPods:
            name.localizedCaseInsensitiveContains("max") ? "airpodsmax"
                : name.localizedCaseInsensitiveContains("pro") ? "airpodspro" : "airpods"
        case .bluetooth: "hifispeaker.fill"
        case .usb: "hifispeaker.2.fill"
        case .display: "tv"
        case .airPlay: "airplayaudio"
        case .other: "speaker.wave.2.fill"
        }
    }

    /// From CoreAudio's transport type (its four letters, e.g. "blue") and the device's name.
    public static func kind(transport: String, name: String) -> Kind {
        switch transport {
        case "bltn": name.localizedCaseInsensitiveContains("headphone") ? .headphones : .builtInSpeakers
        case "blue", "blea": name.localizedCaseInsensitiveContains("airpods") ? .airPods
            : name.localizedCaseInsensitiveContains("headphone") ? .headphones : .bluetooth
        case "usb ": .usb
        case "hdmi", "dprt": .display
        case "airp": .airPlay
        default: .other
        }
    }
}

/// The outputs and the current one. Live: CoreAudio (no permission); tests: a fake.
@MainActor
public protocol AudioOutputsService: AnyObject {
    func outputs() -> [AudioOutput]
    func currentOutput() -> AudioOutput.ID?
    /// Makes `id` the output for all sound, like choosing it in Control Center.
    func select(_ id: AudioOutput.ID) -> Bool
    /// Called when a device comes or goes, or the current output changes.
    var onChange: (() -> Void)? { get set }
    func start()
}

/// The output volume as the HUD shows it.
public struct VolumeState: Equatable, Sendable {
    /// 0 … 1
    public var level: Double
    public var isMuted: Bool
    /// The output's name, e.g. "AirPods Pro". `nil` for the built-in speakers. (Not shown in the HUD since
    /// 2026-10-01: long names got cut off; the HUD shows `output`'s icon instead.)
    public var deviceName: String?
    /// What it plays on, for the HUD's icon. `nil` for the built-in speakers.
    public var output: AudioOutputKind?
    /// Some outputs (HDMI, some USB audio) have no volume control.
    public var isAdjustable: Bool

    public init(level: Double, isMuted: Bool, deviceName: String? = nil, output: AudioOutputKind? = nil,
                isAdjustable: Bool = true) {
        self.level = level
        self.isMuted = isMuted
        self.deviceName = deviceName
        self.output = output
        self.isAdjustable = isAdjustable
    }

    /// The HUD's icon (your pick, 2026-10-01: the output's icon, not its name, like the iPhone): muted or at 0 → the
    /// slashed speaker; another output → its own icon (AirPods, headphones…); the built-in speakers → 1–3 waves.
    public var hudSymbol: String {
        if isMuted || level <= 0.001 { return "speaker.slash.fill" }
        return output?.symbolName ?? symbolName
    }

    /// Apple's speaker symbols: slash when muted or at 0, then 1, 2 or 3 waves by thirds (PRD §7.3).
    public var symbolName: String {
        if isMuted || level <= 0.001 { return "speaker.slash.fill" }
        if level < 1.0 / 3 { return "speaker.wave.1.fill" }
        if level < 2.0 / 3 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

/// What the sound plays on, as an icon.
public enum AudioOutputKind: Equatable, Sendable {
    case airpods, airpodsPro, airpodsMax
    /// Other Bluetooth audio: earbuds and headphones (most Bluetooth outputs are).
    case headphones
    case airplay
    /// HDMI or DisplayPort: a TV or a monitor's speakers.
    case display
    /// USB and the rest.
    case external

    public var symbolName: String {
        switch self {
        case .airpods: "airpods"
        case .airpodsPro: "airpods.pro"
        case .airpodsMax: "airpods.max"
        case .headphones: "headphones"
        case .airplay: "airplayaudio"
        case .display: "tv"
        case .external: "hifispeaker"
        }
    }

    /// From CoreAudio's transport type (its four-character code, e.g. "blue") and model UID. Bluetooth model UIDs
    /// read "<product> <vendor>" in hex: Apple's vendor (4c) names AirPods by product (your other earbuds report
    /// "ffffffff ffffffff", so they're headphones). Nil for the built-in speakers.
    public static func from(transport: String, modelUID: String?) -> AudioOutputKind? {
        switch transport {
        case "bltn": return nil
        case "blue", "blea":
            switch appleProduct(modelUID: modelUID) {
            case "AirPods"?: return .airpods
            case "AirPods Pro"?: return .airpodsPro
            case "AirPods Max"?: return .airpodsMax
            default: return .headphones
            }
        case "airp": return .airplay
        case "hdmi", "dprt": return .display
        default: return .external
        }
    }

    static func appleProduct(modelUID: String?) -> String? {
        guard let parts = modelUID?.split(separator: " "), parts.count == 2,
              let product = Int(parts[0], radix: 16), let vendor = Int(parts[1], radix: 16) else { return nil }
        return DeviceNames.appleProduct(vendorID: vendor, productID: product)
    }
}

public enum VolumeEvent: Equatable, Sendable {
    /// First reading, or the output device changed (e.g. AirPods connected): update quietly, no HUD.
    case baseline(VolumeState)
    /// The level or mute changed: show the HUD.
    case changed(VolumeState)
}

/// Reports and changes the system output volume. The live version uses CoreAudio; tests use a fake.
@MainActor
public protocol VolumeService: AnyObject {
    var events: AsyncStream<VolumeEvent> { get }
    func start()
    /// The current output right now, or nil when there's no output device.
    func currentState() -> VolumeState?
    @discardableResult func setLevel(_ level: Double) -> Bool
    @discardableResult func setMuted(_ muted: Bool) -> Bool
}

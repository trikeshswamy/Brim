import Foundation
import Observation
import BrimCore

/// Brim's own volume and brightness keys (your choice, 2026-09-29: only Brim's HUD).
///
/// Each press moves the level by Brim's step (5%, or 2% with Option-Shift) and shows Brim's HUD.
/// macOS never sees a key Brim handled, so Apple's HUD stays away. Anything Brim can't handle
/// (an output without volume control, no built-in display) goes back to macOS untouched.
@Observable
public final class KeyTakeover {
    public private(set) var access: KeyAccess = .off {
        didSet { hud.quietForOthersChanges = access == .active }
    }
    /// Whether macOS has granted Brim Accessibility / Device Control access, even when Brim's HUD is off.
    public private(set) var permissionGranted = false
    /// Presses Brim has handled since launch (the self-test checks this).
    public private(set) var handledPresses = 0
    /// Self-test only: hand every key to macOS, to prove Apple's HUD can be detected at all.
    @ObservationIgnored public var passThrough = false
    /// ⌃ + a volume key: the music app's own volume instead of the Mac's (your pick, 2026-11-17). Answers at once
    /// whether Music or Spotify is playing (then it's Brim's to handle); false leaves the key to the Mac's volume.
    @ObservationIgnored public var musicVolumeKey: ((_ up: Bool, _ fine: Bool) -> Bool)?

    @ObservationIgnored private let keys: any MediaKeyService
    @ObservationIgnored private let volume: any VolumeService
    @ObservationIgnored private let brightness: any BrightnessService
    @ObservationIgnored private let hud: HUDStore
    /// Keys whose press Brim took, so their release is taken too (and only theirs).
    @ObservationIgnored private var heldKeys: Set<MediaKeyPress.Key> = []

    public init(keys: any MediaKeyService, volume: any VolumeService, brightness: any BrightnessService, hud: HUDStore) {
        self.keys = keys
        self.volume = volume
        self.brightness = brightness
        self.hud = hud
        keys.refreshPermissionStatus()
        permissionGranted = keys.permissionGranted
        keys.onAccessChange = { [weak self] in self?.access = $0 }
    }

    /// Refreshes the status shown in Settings without asking macOS for anything.
    public func refreshPermissionStatus() {
        keys.refreshPermissionStatus()
        permissionGranted = keys.permissionGranted
    }

    /// Settings → HUD → "Show only Brim's HUD".
    public func setEnabled(_ enabled: Bool) {
        if enabled {
            refreshPermissionStatus()
            keys.start { [weak self] press in self?.handle(press) ?? false }
        } else {
            keys.stop()
            refreshPermissionStatus()
        }
        access = keys.access
        permissionGranted = keys.permissionGranted
    }

    /// `true`: Brim handled the key, macOS must not see it. `false`: macOS gets it.
    func handle(_ press: MediaKeyPress) -> Bool {
        guard press.isDown else { return heldKeys.remove(press.key) != nil }
        guard !passThrough, apply(press) else {
            Log.app.info("Key \(String(describing: press.key), privacy: .public): left to macOS")
            return false
        }
        heldKeys.insert(press.key)
        handledPresses += 1
        Log.app.info("Key \(String(describing: press.key), privacy: .public)\(press.fine ? " (fine)" : "", privacy: .public): handled by Brim")
        return true
    }

    private func apply(_ press: MediaKeyPress) -> Bool {
        switch press.key {
        case .volumeUp, .volumeDown, .mute:
            if press.control, press.key != .mute, musicVolumeKey?(press.key == .volumeUp, press.fine) == true { return true }
            // Outputs without a volume control (some HDMI or USB) stay with macOS, which explains that itself.
            guard let state = volume.currentState(), state.isAdjustable else { return false }
            if press.key == .mute {
                volume.setMuted(!state.isMuted)
            } else {
                if state.isMuted { volume.setMuted(false) }  // like macOS: a volume key unmutes
                volume.setLevel(LevelStep.next(from: state.level, up: press.key == .volumeUp, fine: press.fine))
            }
            hud.volumeKeyPressed(volume.currentState() ?? state)  // shows even at 0% or 100%, where nothing moves
            return true
        case .brightnessUp, .brightnessDown:
            guard let level = brightness.level() else { return false }
            let next = LevelStep.next(from: level, up: press.key == .brightnessUp, fine: press.fine)
            guard brightness.setLevel(next) else { return false }
            hud.brightnessChanged(to: next)
            return true
        }
    }
}

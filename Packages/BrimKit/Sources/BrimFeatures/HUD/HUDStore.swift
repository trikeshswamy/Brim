import Foundation
import Observation
import BrimCore

/// Volume and brightness for the HUD views.
/// A real change posts a HUD activity to the island; a quiet baseline (first read, device switch) doesn't.
@Observable
public final class HUDStore {
    public private(set) var volume: VolumeState?
    /// Set when a brightness key is handled. (macOS's own brightness signal also fires for automatic
    /// brightness, so the HUD follows key presses only.)
    public private(set) var brightness: BrightnessState?
    /// Which HUD is on screen right now (1.5 s after a change). The open island shows it as a banner.
    public private(set) var showing: HUDKind?
    /// The music app's own volume (0…1) while ⌃ + a volume key just changed it: the volume HUD shows this, with a
    /// note, instead of the Mac's level (your pick, 2026-11-17). Nil the rest of the time.
    public private(set) var appVolume: Double?
    /// Whose: "Music" or "Spotify", shown in the HUD so with both playing you see which one ⌃ turned.
    public private(set) var appVolumeName: String?
    @ObservationIgnored private var forgetAppVolume: Task<Void, Never>?

    @ObservationIgnored private let volumeService: any VolumeService
    @ObservationIgnored private let island: IslandCoordinator
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var hideBanner: Task<Void, Never>?
    /// On while Brim takes the volume keys ("Show only Brim's HUD"). Then a change Brim didn't make (AirPods' or
    /// earbuds' own buttons: they change the volume directly, no key is pressed) already has Apple's HUD on screen, and
    /// no app can hide that one, so Brim doesn't add a second (your report, 2026-10-29: both showed at once).
    @ObservationIgnored public var quietForOthersChanges = false
    /// When Brim last changed the volume itself (a key it handled, its own slider).
    @ObservationIgnored private var ownChange = Date.distantPast

    public init(volume: any VolumeService, island: IslandCoordinator) {
        self.volumeService = volume
        self.island = island
    }

    public func start() {
        guard listener == nil else { return }
        let events = volumeService.events
        listener = Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
        volumeService.start()
    }

    /// Internal so tests can feed events directly.
    func handle(_ event: VolumeEvent) {
        switch event {
        case .baseline(let state):
            volume = state
        case .changed(let state):
            volume = state
            if quietForOthersChanges, Date.now.timeIntervalSince(ownChange) > 1 {
                Log.app.info("Volume changed outside Brim (earbuds, Control Center…): Apple's HUD shows, Brim's stays away")
                return
            }
            island.post(.hud(.volume, at: .now))
            showBanner(.volume)
        }
    }

    /// The full-screen player's slider. CoreAudio reports the change back, which updates `volume`.
    public func setVolume(_ level: Double) {
        ownChange = .now
        if volume?.isMuted == true { volumeService.setMuted(false) }
        volumeService.setLevel(min(max(level, 0), 1))
    }

    /// ⌃ + a volume key changed the music app's own volume: the HUD shows it, as for the Mac's volume.
    public func appVolumeChanged(to level: Double, app: String? = nil) {
        appVolume = min(max(level, 0), 1)
        appVolumeName = app
        island.post(.hud(.volume, at: .now))
        showBanner(.volume)
        forgetAppVolume?.cancel()
        forgetAppVolume = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))  // past the HUD's time on screen
            guard !Task.isCancelled else { return }
            self?.appVolume = nil
        }
    }

    /// A volume key was handled: show the HUD with the new level, even when it didn't change (0% or 100%).
    public func volumeKeyPressed(_ state: VolumeState) {
        forgetAppVolume?.cancel()
        appVolume = nil
        ownChange = .now
        volume = state
        island.post(.hud(.volume, at: .now))
        showBanner(.volume)
    }

    /// A brightness key changed the level: show the brightness HUD for 1.5 s, like volume.
    public func brightnessChanged(to level: Double) {
        brightness = BrightnessState(level: min(max(level, 0), 1))
        island.post(.hud(.brightness, at: .now))
        showBanner(.brightness)
    }

    private func showBanner(_ kind: HUDKind) {
        showing = kind
        hideBanner?.cancel()
        hideBanner = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.showing = nil
        }
    }
}

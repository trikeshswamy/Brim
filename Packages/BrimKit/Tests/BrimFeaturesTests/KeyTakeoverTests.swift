import Testing
@testable import BrimCore
@testable import BrimFeatures

final class FakeMediaKeyService: MediaKeyService {
    var access: KeyAccess = .off
    var permissionGranted = true
    var onAccessChange: ((KeyAccess) -> Void)?
    private(set) var handler: ((MediaKeyPress) -> Bool)?

    func refreshPermissionStatus() {}
    func start(handler: @escaping (MediaKeyPress) -> Bool) { self.handler = handler; access = .active }
    func stop() { handler = nil; access = .off }
}

final class FakeBrightnessService: BrightnessService {
    var value: Double? = 0.6173
    var canSet = true
    func level() -> Double? { value }
    func setLevel(_ level: Double) -> Bool { if canSet { value = level }; return canSet }
}

struct KeyTakeoverTests {
    private struct Rig {
        let takeover: KeyTakeover
        let volume: FakeVolumeService
        let brightness: FakeBrightnessService
        let hud: HUDStore
        let island: IslandCoordinator
    }

    private func makeRig() -> Rig {
        let island = IslandCoordinator()
        let volume = FakeVolumeService()
        let brightness = FakeBrightnessService()
        let hud = HUDStore(volume: volume, island: island)
        let takeover = KeyTakeover(keys: FakeMediaKeyService(), volume: volume, brightness: brightness, hud: hud)
        takeover.setEnabled(true)
        return Rig(takeover: takeover, volume: volume, brightness: brightness, hud: hud, island: island)
    }

    @Test func permissionStatusIsVisibleWhileBrimHUDIsOff() {
        let island = IslandCoordinator()
        let volume = FakeVolumeService()
        let brightness = FakeBrightnessService()
        let hud = HUDStore(volume: volume, island: island)
        let takeover = KeyTakeover(keys: FakeMediaKeyService(), volume: volume, brightness: brightness, hud: hud)

        #expect(takeover.access == .off)
        #expect(takeover.permissionGranted)
    }

    private func press(_ key: MediaKeyPress.Key, fine: Bool = false) -> MediaKeyPress {
        MediaKeyPress(key: key, isDown: true, fine: fine)
    }

    /// Your pick, 2026-11-17: ⌃ + a volume key changes only the music app's own volume while Music or Spotify plays;
    /// the Mac's volume stays. With nothing for it (another app playing), the key is the Mac's volume as usual.
    @Test func controlVolumeKeysGoToTheMusicApp() {
        let rig = makeRig()
        var asked: [(Bool, Bool)] = []
        var musicPlaying = true
        rig.takeover.musicVolumeKey = { up, fine in asked.append((up, fine)); return musicPlaying }
        let before = rig.volume.state?.level
        #expect(rig.takeover.handle(MediaKeyPress(key: .volumeDown, isDown: true, control: true)))
        #expect(asked.count == 1 && asked[0].0 == false)
        #expect(rig.volume.state?.level == before)                       // the Mac's volume didn't move
        musicPlaying = false
        #expect(rig.takeover.handle(MediaKeyPress(key: .volumeUp, isDown: true, control: true)))
        #expect(rig.volume.state?.level != before)                       // nothing to hand it to: the Mac's volume
        #expect(MediaKeyPress.decode(data1: 0x0000_0A00, optionShift: false, control: true)?.control == true)
    }

    @Test func volumeKeysStepFivePercentAndShowBrimsHUD() {
        let rig = makeRig()
        #expect(rig.takeover.handle(press(.volumeUp)))  // swallowed: macOS never sees it
        #expect(rig.volume.state?.level == 0.45)
        #expect(rig.island.surface == .compact(.hud(.volume)))
        #expect(rig.takeover.handle(press(.volumeDown)))
        #expect(rig.volume.state?.level == 0.40)
    }

    @Test func optionShiftStepsTwoPercent() {
        let rig = makeRig()
        _ = rig.takeover.handle(press(.volumeUp, fine: true))
        #expect(rig.volume.state?.level == 0.44)
        _ = rig.takeover.handle(press(.brightnessDown, fine: true))
        #expect(rig.brightness.value == 0.60)
    }

    @Test func muteTogglesAndAVolumeKeyUnmutes() {
        let rig = makeRig()
        _ = rig.takeover.handle(press(.mute))
        #expect(rig.volume.state?.isMuted == true)
        #expect(rig.hud.volume?.isMuted == true)  // the HUD shows the muted speaker
        _ = rig.takeover.handle(press(.volumeUp))
        #expect(rig.volume.state?.isMuted == false)
    }

    @Test func atFullVolumeTheHUDStillShows() {
        let rig = makeRig()
        rig.volume.state?.level = 1
        #expect(rig.takeover.handle(press(.volumeUp)))
        #expect(rig.volume.state?.level == 1)
        #expect(rig.hud.showing == .volume)
    }

    @Test func brightnessKeysStepAndShowBrimsHUD() {
        let rig = makeRig()
        #expect(rig.takeover.handle(press(.brightnessUp)))
        #expect(rig.brightness.value == 0.65)
        #expect(rig.hud.brightness == BrightnessState(level: 0.65))
        #expect(rig.island.surface == .compact(.hud(.brightness)))
    }

    @Test func releaseIsTakenOnlyAfterBrimTookThePress() {
        let rig = makeRig()
        #expect(rig.takeover.handle(MediaKeyPress(key: .volumeUp, isDown: false)) == false)  // never pressed
        _ = rig.takeover.handle(press(.volumeUp))
        #expect(rig.takeover.handle(MediaKeyPress(key: .volumeUp, isDown: false)))
    }

    @Test func whatBrimCantHandleGoesBackToMacOS() {
        let rig = makeRig()
        rig.volume.state?.isAdjustable = false            // e.g. an HDMI output
        #expect(rig.takeover.handle(press(.volumeUp)) == false)
        rig.brightness.value = nil                         // lid closed: no built-in display
        #expect(rig.takeover.handle(press(.brightnessUp)) == false)
        #expect(rig.takeover.handledPresses == 0)
    }

    @Test func passThroughHandsEveryKeyToMacOS() {
        let rig = makeRig()
        rig.takeover.passThrough = true
        #expect(rig.takeover.handle(press(.volumeUp)) == false)
        #expect(rig.volume.state?.level == 0.4375)  // untouched: macOS does the change
    }

    @Test func switchingOffStopsTheTakeover() {
        let rig = makeRig()
        #expect(rig.takeover.access == .active)
        rig.takeover.setEnabled(false)
        #expect(rig.takeover.access == .off)
    }
}

/// Earbuds and AirPods change the volume without a key, and macOS shows Apple's HUD for that, which no app can hide:
/// while Brim owns the keys it doesn't add a second HUD (your report, 2026-10-29). Its own changes still show.
@MainActor
struct OutsideVolumeChangeTests {
    @Test func earbudChangesLeaveOnlyApplesHUD() {
        let island = IslandCoordinator()
        let volume = FakeVolumeService()
        let hud = HUDStore(volume: volume, island: island)
        let takeover = KeyTakeover(keys: FakeMediaKeyService(), volume: volume, brightness: FakeBrightnessService(), hud: hud)
        takeover.setEnabled(true)
        #expect(hud.quietForOthersChanges)
        hud.handle(.changed(VolumeState(level: 0.4, isMuted: false)))
        #expect(hud.showing == nil && hud.volume?.level == 0.4)  // the level still follows, silently
        // Brim's own change (its slider here): the report that follows shows Brim's HUD.
        hud.setVolume(0.5)
        hud.handle(.changed(VolumeState(level: 0.5, isMuted: false)))
        #expect(hud.showing == .volume)
        // "Show only Brim's HUD" off: both HUDs show, as before.
        takeover.setEnabled(false)
        #expect(!hud.quietForOthersChanges)
    }
}

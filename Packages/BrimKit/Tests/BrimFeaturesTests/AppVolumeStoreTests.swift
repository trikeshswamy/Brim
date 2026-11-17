import Foundation
import Testing
@testable import BrimCore
@testable import BrimFeatures

/// Music's or Spotify's own volume for the full-screen slider (your find, 2026-11-17: Apple Music's slider turns only
/// Music down; other apps keep the Mac's volume).
private actor VolumeControls: PlayerControlsService {
    var volume: Int? = 60
    private(set) var sent: [Int] = []
    /// The app changing its own volume (Music on a resume, or you in Music's window).
    func appChanged(to level: Int) { volume = level }
    func modes(of player: ScriptablePlayer, track: String?) async -> PlayerModes? { nil }
    func setShuffle(_ on: Bool, in player: ScriptablePlayer) async -> Bool { false }
    func setRepeat(_ mode: RepeatMode, in player: ScriptablePlayer) async -> Bool { false }
    func setFavorite(_ on: Bool, in player: ScriptablePlayer, track: String?) async -> Bool { false }
    func perform(_ command: MediaCommand, in player: ScriptablePlayer) async -> Bool { false }
    func seek(to position: TimeInterval, in player: ScriptablePlayer) async -> Bool { false }
    func position(of player: ScriptablePlayer) async -> (seconds: Double, roundTrip: TimeInterval)? { nil }
    func appVolume(in player: ScriptablePlayer) async -> Int? { volume }
    func setAppVolume(_ level: Int, in player: ScriptablePlayer) async -> Bool {
        try? await Task.sleep(for: .milliseconds(30))  // an Apple Event takes a moment
        sent.append(level)
        volume = level
        return true
    }
}

@MainActor
struct AppVolumeStoreTests {
    private func store(app: String?) -> (AppVolumeStore, VolumeControls) {
        let nowPlaying = NowPlayingStore(service: FakeNowPlayingService(), island: IslandCoordinator())
        nowPlaying.handle(.item(NowPlaying(title: "Song", artist: "A", bundleIdentifier: app, isPlaying: true)))
        let controls = VolumeControls()
        return (AppVolumeStore(service: controls, nowPlaying: nowPlaying), controls)
    }

    @Test func musicsOwnVolumeIsReadAndADragSendsOnlyTheLatest() async throws {
        let (volume, controls) = store(app: "com.apple.Music")
        volume.refresh()
        for _ in 0..<50 where volume.level == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(volume.level == 0.6)
        for step in 1...10 { volume.set(Double(step) / 20) }  // a quick drag: 0.05 … 0.5
        #expect(volume.level == 0.5)                           // shown at once
        for _ in 0..<200 where await controls.sent.last != 50 { try await Task.sleep(for: .milliseconds(10)) }
        let sent = await controls.sent
        #expect(sent.last == 50 && sent.count <= 3)            // not ten Apple Events
    }

    /// Your case, 2026-11-17: a meeting in Dia on screen, Spotify playing behind it: ⌃ + volume still turns Spotify.
    @Test func controlVolumeFindsTheMusicBehindAMeeting() async throws {
        let nowPlaying = NowPlayingStore(service: FakeNowPlayingService(), island: IslandCoordinator())
        nowPlaying.handle(.item(NowPlaying(title: "Standup", artist: nil, bundleIdentifier: "company.thebrowser.dia", isPlaying: true)))
        #expect(nowPlaying.musicApp == nil)                                   // nothing of yours: the Mac's volume
        nowPlaying.handle(PlayerAnnouncement(player: .spotify, state: .playing, title: "Song", date: .now))
        #expect(nowPlaying.musicApp == .spotify)
        let controls = VolumeControls()
        let volume = AppVolumeStore(service: controls, nowPlaying: nowPlaying)
        #expect(volume.step(up: false, fine: false))
        // Waits for it (up to 2 s), never a fixed pause: a busy Mac made a 0.2 s one fail once (2026-11-17).
        for _ in 0..<200 where await controls.sent.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await controls.sent.last == 55)                               // 60 → 55: Spotify, not the Mac
    }

    /// Your report, 2026-11-17: Music came back loud after a pause and play. Back at its old level → yours again;
    /// changed to something else in Music → that's yours, and Brim lets it be.
    @Test func yourLevelSurvivesAResume() async throws {
        let (volume, controls) = store(app: "com.apple.Music")
        volume.resumeCheckDelay = .milliseconds(10)
        #expect(volume.step(up: false, fine: false))                 // 60 → 55
        for _ in 0..<200 where await controls.sent.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        await controls.appChanged(to: 60)                             // Music jumps back on resume
        volume.resumed(.music)
        for _ in 0..<200 where await controls.sent.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await controls.sent == [55, 55])                      // set again

        await controls.appChanged(to: 30)                             // you turned it down in Music itself
        volume.resumed(.music)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await controls.sent == [55, 55])                      // left alone
        await controls.appChanged(to: 60)
        volume.resumed(.music)                                        // and forgotten: no more resets
        try await Task.sleep(for: .milliseconds(150))
        #expect(await controls.sent == [55, 55])
    }

    @Test func anotherAppKeepsTheMacsVolume() async throws {
        let (volume, _) = store(app: "com.google.Chrome")
        volume.refresh()
        try await Task.sleep(for: .milliseconds(100))
        #expect(volume.level == nil && volume.player == nil)
    }
}

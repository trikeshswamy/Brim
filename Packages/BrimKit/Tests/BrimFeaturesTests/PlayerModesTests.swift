import Foundation
import Testing
@testable import BrimCore
@testable import BrimFeatures

/// Stands in for Spotify/Music: remembers what was set.
actor FakePlayerControls: PlayerControlsService {
    var current: PlayerModes?
    private(set) var sets: [String] = []
    /// False: like Spotify 1.3.3 (2026-10-02), it answers nothing; reads give nil, commands fail.
    var answers: Bool

    init(_ modes: PlayerModes?, answers: Bool = true) {
        current = modes
        self.answers = answers
    }

    func setAnswers(_ value: Bool) { answers = value }

    /// The Spotify songs Brim named when reading, for ★.
    private(set) var readTracks: [String?] = []
    func modes(of player: ScriptablePlayer, track: String?) async -> PlayerModes? {
        readTracks.append(track)
        return answers ? current : nil
    }
    func setShuffle(_ on: Bool, in player: ScriptablePlayer) async -> Bool {
        sets.append("shuffle \(on)")
        current?.shuffle = on
        return true
    }
    func setRepeat(_ mode: RepeatMode, in player: ScriptablePlayer) async -> Bool {
        sets.append("repeat \(mode)")
        current?.repeatMode = mode
        return true
    }
    func setFavorite(_ on: Bool, in player: ScriptablePlayer, track: String?) async -> Bool {
        sets.append(["favorite \(on)", track].compactMap { $0 }.joined(separator: " "))
        current?.favorite = on
        return true
    }
    private(set) var commands: [String] = []
    func perform(_ command: MediaCommand, in player: ScriptablePlayer) async -> Bool {
        commands.append("\(command) → \(player)")
        return answers
    }
    func seek(to position: TimeInterval, in player: ScriptablePlayer) async -> Bool {
        commands.append("seek \(Int(position)) → \(player)")
        return answers
    }
    var position: Double?
    func position(of player: ScriptablePlayer) async -> (seconds: Double, roundTrip: TimeInterval)? {
        position.map { ($0, 0.01) }
    }
}

struct PlayerModesTests {
    private func playing(_ bundleID: String) -> NowPlayingStore {
        let store = NowPlayingStore(service: FakeNowPlayingService(), island: IslandCoordinator())
        store.handle(.item(NowPlaying(title: "Song", artist: "Artist", bundleIdentifier: bundleID, isPlaying: true)))
        return store
    }

    private func settle(_ store: PlayerModesStore, until condition: (PlayerModesStore) -> Bool) async {
        for _ in 0..<100 where !condition(store) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func readsModesForSpotifyAndMusicOnly() async {
        let spotify = PlayerModesStore(service: FakePlayerControls(PlayerModes(shuffle: true, repeatMode: .off)),
                                       nowPlaying: playing("com.spotify.client"))
        spotify.refresh()
        await settle(spotify) { $0.modes != nil }
        #expect(spotify.modes == PlayerModes(shuffle: true, repeatMode: .off))

        let safari = PlayerModesStore(service: FakePlayerControls(PlayerModes(shuffle: true, repeatMode: .off)),
                                      nowPlaying: playing("com.apple.Safari"))
        safari.refresh()
        #expect(safari.modes == nil)  // YouTube and websites: no buttons
    }

    @Test func clickFlipsAtOnceThenThePlayerDecides() async {
        let fake = FakePlayerControls(PlayerModes(shuffle: false, repeatMode: .off))
        let store = PlayerModesStore(service: fake, nowPlaying: playing("com.apple.Music"))
        store.refresh()
        await settle(store) { $0.modes != nil }
        store.toggleShuffle()
        #expect(store.modes?.shuffle == true)          // instant
        store.cycleRepeat()
        #expect(store.modes?.repeatMode == .all)
        await settle(store) { _ in false }             // let the sets and re-reads finish
        #expect(await fake.sets == ["shuffle true", "repeat all"])
    }

    @Test func lockedSpotifyIgnoresClicks() async {
        let fake = FakePlayerControls(PlayerModes(shuffle: false, repeatMode: .off, canChange: false))
        let store = PlayerModesStore(service: fake, nowPlaying: playing("com.spotify.client"))
        store.refresh()
        await settle(store) { $0.modes != nil }
        store.toggleShuffle()
        #expect(store.modes?.shuffle == false)
        #expect(await fake.sets.isEmpty)
    }

    /// Your report (2026-10-02): Spotify 1.3.3 answered no reads, and Shuffle & Repeat vanished without a word.
    @Test func aPlayerThatDoesntAnswerIsMarkedUntilItDoes() async {
        let fake = FakePlayerControls(PlayerModes(shuffle: true, repeatMode: .off), answers: false)
        let store = PlayerModesStore(service: fake, nowPlaying: playing("com.spotify.client"))
        store.refresh()
        await settle(store) { $0.unreachable }
        #expect(store.unreachable && store.modes == nil)   // faded, with the reason
        await fake.setAnswers(true)
        store.refresh()                                   // the island opens again: it answers
        await settle(store) { $0.modes != nil }
        #expect(!store.unreachable)
        #expect(store.modes == PlayerModes(shuffle: true, repeatMode: .off))
    }

    /// Your report (2026-10-02): Brim showed Off while Spotify sat on Repeat One. Spotify's menu has one checkmark for
    /// All and One, and each press moves one step; Brim now presses once per click and shows what Spotify reports.
    @Test func spotifysMenuRepeatMovesOneStepAndShowsWhatSpotifyReports() async {
        let spotify = SpotifyMenuRepeat()
        let store = PlayerModesStore(service: spotify, nowPlaying: playing("com.spotify.client"))
        store.refresh()
        await settle(store) { $0.modes != nil }
        store.cycleRepeat()                                      // off → all
        #expect(store.modes?.repeatMode == .all)                 // shown at once: off → on is certain
        await waitFor(spotify, step: 1)
        store.cycleRepeat()                                      // all → one: Brim can't tell, so no guess
        #expect(store.modes?.repeatMode == .all)
        await waitFor(spotify, step: 2)
        await longSettle(store) { _ in false }
        #expect(store.modes?.repeatMode == .all)                 // Spotify says "on" (One): Brim agrees
        store.cycleRepeat()                                      // one → off
        await longSettle(store) { $0.modes?.repeatMode == .off }
        #expect(store.modes?.repeatMode == .off)
        #expect(await spotify.step == 0)
        #expect(await spotify.presses == 3)                      // exactly one press per click
    }

    /// Your report (2026-10-02): no "1" and a lag on Off. Through Spotify's Web API Brim knows all three states, so each
    /// click shows the next one at once, like Apple Music: off → all → one → off.
    @Test func spotifyThroughItsWebAPICyclesAllThreeAtOnce() async {
        let fake = FakePlayerControls(PlayerModes(shuffle: false, repeatMode: .off, repeatHasOne: true))
        let store = PlayerModesStore(service: fake, nowPlaying: playing("com.spotify.client"))
        store.refresh()
        await settle(store) { $0.modes != nil }
        store.cycleRepeat()
        #expect(store.modes?.repeatMode == .all)    // at once
        store.cycleRepeat()
        #expect(store.modes?.repeatMode == .one)    // the "1"
        store.cycleRepeat()
        #expect(store.modes?.repeatMode == .off)
        await settle(store) { _ in false }
        #expect(await fake.sets == ["repeat all", "repeat one", "repeat off"])
    }

    private func waitFor(_ spotify: SpotifyMenuRepeat, step: Int) async {
        for _ in 0..<200 where await spotify.step != step { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(await spotify.step == step)
    }

    private func longSettle(_ store: PlayerModesStore, until condition: (PlayerModesStore) -> Bool) async {
        for _ in 0..<250 where !condition(store) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// Switching from a video back to Spotify shows its last buttons at once (a Web API read takes ~0.2 s), then reads again.
    @Test func switchingBackShowsTheLastButtonsAtOnce() async {
        let fake = FakePlayerControls(PlayerModes(shuffle: true, repeatMode: .one, repeatHasOne: true))
        let nowPlaying = NowPlayingStore(service: FakeNowPlayingService(), island: IslandCoordinator())
        let spotify = NowPlaying(title: "Song", artist: "Artist", bundleIdentifier: "com.spotify.client", isPlaying: true)
        nowPlaying.handle(.item(spotify))
        let store = PlayerModesStore(service: fake, nowPlaying: nowPlaying)
        store.refresh()
        await settle(store) { $0.modes != nil }
        var paused = spotify
        paused.isPlaying = false
        nowPlaying.handle(.item(paused))                     // you pause Spotify…
        let video = NowPlaying(title: "A video", bundleIdentifier: "company.thebrowser.dia", isPlaying: true)
        nowPlaying.handle(.item(video))                      // …and play a video
        store.refresh()
        #expect(store.modes == nil)                          // a website: no buttons
        var pausedVideo = video
        pausedVideo.isPlaying = false
        nowPlaying.handle(.item(pausedVideo))                // pause it…
        nowPlaying.handle(.item(spotify))                    // …and play Spotify again
        store.refresh()
        #expect(store.modes?.repeatMode == .one)             // at once, before any read
    }

    @Test func repeatCyclesDependOnThePlayer() {
        #expect(RepeatMode.off.next(hasOne: true) == .all)    // Music; Spotify through its Web API
        #expect(RepeatMode.all.next(hasOne: true) == .one)
        #expect(RepeatMode.one.next(hasOne: true) == .off)
        #expect(RepeatMode.off.next(hasOne: false) == .all)
        #expect(RepeatMode.all.next(hasOne: false) == .off)   // Spotify's scripting has no "repeat one"
    }
}

/// Spotify through its menu (2026-10-02): Repeat is 3 steps (off → all → one) behind one checkmark; each press moves
/// one step.
actor SpotifyMenuRepeat: PlayerControlsService {
    private(set) var step = 0
    private(set) var presses = 0
    func modes(of player: ScriptablePlayer, track: String?) async -> PlayerModes? {
        PlayerModes(shuffle: false, repeatMode: step == 0 ? .off : .all, repeatOnMayBeOne: true)
    }
    func setShuffle(_ on: Bool, in player: ScriptablePlayer) async -> Bool { true }
    func setRepeat(_ mode: RepeatMode, in player: ScriptablePlayer) async -> Bool {
        presses += 1
        step = (step + 1) % 3
        return true
    }
    func setFavorite(_ on: Bool, in player: ScriptablePlayer, track: String?) async -> Bool { false }
    func perform(_ command: MediaCommand, in player: ScriptablePlayer) async -> Bool { true }
    func seek(to position: TimeInterval, in player: ScriptablePlayer) async -> Bool { true }
    func position(of player: ScriptablePlayer) async -> (seconds: Double, roundTrip: TimeInterval)? { nil }
}

/// A player that applies a change only after a delay (Music: 0.3–1 s, measured 2026-09-30), or never.
actor SlowPlayerControls: PlayerControlsService {
    private var current: PlayerModes
    private let delay: Duration?
    private(set) var sets: [String] = []
    /// Changes waiting to take effect, in the order they were sent (a real player handles them in order).
    private var pending: [(due: ContinuousClock.Instant, change: @Sendable (inout PlayerModes) -> Void)] = []

    init(_ modes: PlayerModes, appliesAfter delay: Duration?) {
        current = modes
        self.delay = delay
    }

    func modes(of player: ScriptablePlayer, track: String?) async -> PlayerModes? {
        let now = ContinuousClock.now
        while let first = pending.first, first.due <= now {
            first.change(&current)
            pending.removeFirst()
        }
        return current
    }
    func setShuffle(_ on: Bool, in player: ScriptablePlayer) async -> Bool {
        sets.append("shuffle \(on)")
        apply { $0.shuffle = on }
        return true
    }
    func setRepeat(_ mode: RepeatMode, in player: ScriptablePlayer) async -> Bool {
        sets.append("repeat \(mode)")
        apply { $0.repeatMode = mode }
        return true
    }
    func setFavorite(_ on: Bool, in player: ScriptablePlayer, track: String?) async -> Bool { true }
    func perform(_ command: MediaCommand, in player: ScriptablePlayer) async -> Bool { true }
    func seek(to position: TimeInterval, in player: ScriptablePlayer) async -> Bool { true }
    func position(of player: ScriptablePlayer) async -> (seconds: Double, roundTrip: TimeInterval)? { nil }

    private func apply(_ change: @escaping @Sendable (inout PlayerModes) -> Void) {
        guard let delay else { return }  // a player that ignores it
        pending.append((due: ContinuousClock.now + delay, change: change))
    }
}

/// Your fix round 2, item 9: Shuffle and Repeat in Apple Music.
@Suite(.serialized)
struct PlayerModesConfirmTests {
    private let quick: [Duration] = [.milliseconds(60), .milliseconds(120), .milliseconds(240), .milliseconds(400)]

    private func musicPlaying(_ fake: FakeNowPlayingService = FakeNowPlayingService()) -> NowPlayingStore {
        let store = NowPlayingStore(service: fake, island: IslandCoordinator())
        store.handle(.item(NowPlaying(title: "Song", artist: "Artist", bundleIdentifier: "com.apple.Music", isPlaying: true)))
        return store
    }

    private func ready(_ store: PlayerModesStore) async {
        store.refresh()
        for _ in 0..<100 where store.modes == nil { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aSlowPlayerDoesNotFlipTheButtonBack() async {
        let slow = SlowPlayerControls(PlayerModes(shuffle: false, repeatMode: .off), appliesAfter: .milliseconds(180))
        let store = PlayerModesStore(service: slow, nowPlaying: musicPlaying(), confirmAt: quick)
        await ready(store)
        store.toggleShuffle()
        try? await Task.sleep(for: .milliseconds(100))   // the first read back still says "off"
        #expect(store.modes?.shuffle == true)             // the button keeps your click
        try? await Task.sleep(for: .milliseconds(400))
        #expect(store.modes?.shuffle == true)             // and the player confirmed it
    }

    @Test func aChangeThePlayerIgnoresShowsTheTruth() async {
        let deaf = SlowPlayerControls(PlayerModes(shuffle: false, repeatMode: .off), appliesAfter: nil)
        let store = PlayerModesStore(service: deaf, nowPlaying: musicPlaying(), confirmAt: quick)
        await ready(store)
        store.cycleRepeat()
        #expect(store.modes?.repeatMode == .all)          // your click, at once
        try? await Task.sleep(for: .milliseconds(600))
        #expect(store.modes?.repeatMode == .off)          // the player never took it: the button says so
    }

    @Test func quickClicksAreAllSentAndTheLastOneDecides() async {
        let slow = SlowPlayerControls(PlayerModes(shuffle: false, repeatMode: .off), appliesAfter: .milliseconds(150))
        let store = PlayerModesStore(service: slow, nowPlaying: musicPlaying(), confirmAt: quick)
        await ready(store)
        store.cycleRepeat()                               // all
        store.cycleRepeat()                               // one
        try? await Task.sleep(for: .milliseconds(700))
        #expect(await slow.sets == ["repeat all", "repeat one"])
        #expect(store.modes?.repeatMode == .one)
    }

    @Test func musicAlsoGetsControlCentersRoute() async {
        let route = FakeNowPlayingService()
        let fake = FakePlayerControls(PlayerModes(shuffle: false, repeatMode: .off))
        let store = PlayerModesStore(service: fake, nowPlaying: musicPlaying(route), confirmAt: quick)
        await ready(store)
        store.toggleShuffle()
        store.cycleRepeat()
        for _ in 0..<100 where route.modeSets.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(route.modeSets == ["shuffle true", "repeat all"])
        #expect(await fake.sets == ["shuffle true", "repeat all"])  // and the Apple Events, as before
    }

    @Test func spotifyGetsAppleEventsOnly() async {
        let route = FakeNowPlayingService()
        let nowPlaying = NowPlayingStore(service: route, island: IslandCoordinator())
        nowPlaying.handle(.item(NowPlaying(title: "Song", artist: "Artist", bundleIdentifier: "com.spotify.client", isPlaying: true)))
        let fake = FakePlayerControls(PlayerModes(shuffle: false, repeatMode: .off))
        let store = PlayerModesStore(service: fake, nowPlaying: nowPlaying, confirmAt: quick)
        await ready(store)
        store.toggleShuffle()
        for _ in 0..<100 where await fake.sets.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(route.modeSets.isEmpty)                   // Spotify ignores that route (checked 2026-09-29)
    }

    @Test func matchingIgnoresAnUnknownFavorite() {
        let wanted = PlayerModes(shuffle: true, repeatMode: .one, favorite: true)
        #expect(PlayerModes(shuffle: true, repeatMode: .one, favorite: nil).matches(wanted))
        #expect(!PlayerModes(shuffle: true, repeatMode: .all, favorite: true).matches(wanted))
        #expect(!PlayerModes(shuffle: true, repeatMode: .one, favorite: false).matches(wanted))
    }
}

struct FavoriteTests {
    @Test func favoriteFlipsAndMusicConfirms() async {
        let nowPlaying = NowPlayingStore(service: FakeNowPlayingService(), island: IslandCoordinator())
        nowPlaying.handle(.item(NowPlaying(title: "Song", artist: "Artist", bundleIdentifier: "com.apple.Music", isPlaying: true)))
        let fake = FakePlayerControls(PlayerModes(shuffle: false, repeatMode: .off, favorite: false))
        let store = PlayerModesStore(service: fake, nowPlaying: nowPlaying)
        store.refresh()
        for _ in 0..<100 where store.modes == nil { try? await Task.sleep(for: .milliseconds(10)) }
        store.toggleFavorite()
        #expect(store.modes?.favorite == true)                      // at once
        for _ in 0..<100 where await fake.sets.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(await fake.sets == ["favorite true"])
    }

    /// 0.18.3: Spotify's ★ goes to the song its app announced, never one its Web API still reports from before.
    @Test func spotifyFavoriteGoesToTheSongSpotifyAnnounced() async {
        let nowPlaying = NowPlayingStore(service: FakeNowPlayingService(), island: IslandCoordinator())
        let song = "spotify:track:2qxmye6gAegTMjLKEBoR3d"
        // macOS's Now Playing shows Spotify; Spotify's own announcement names the song.
        nowPlaying.handle(.item(NowPlaying(title: "Song", artist: "Artist", bundleIdentifier: "com.spotify.client", isPlaying: true)))
        nowPlaying.handle(PlayerAnnouncement(player: .spotify, state: .playing, title: "Song", artist: "Artist",
                                             album: "Album", duration: 200, position: 30, trackID: song, date: .now))
        let fake = FakePlayerControls(PlayerModes(shuffle: false, repeatMode: .off, favorite: false))
        let store = PlayerModesStore(service: fake, nowPlaying: nowPlaying)
        store.refresh()
        for _ in 0..<100 where store.modes == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(await fake.readTracks.first == song)                  // ★'s question names the song
        store.toggleFavorite()
        #expect(store.modes?.favorite == true)                        // at once
        for _ in 0..<100 where await fake.sets.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(await fake.sets == ["favorite true \(song)"])
    }

    /// Music has no song names to pass: its ★ is the current track's.
    @Test func musicReadsNameNoSong() async {
        let nowPlaying = NowPlayingStore(service: FakeNowPlayingService(), island: IslandCoordinator())
        nowPlaying.handle(.item(NowPlaying(title: "Song", artist: "Artist", bundleIdentifier: "com.apple.Music", isPlaying: true)))
        let fake = FakePlayerControls(PlayerModes(shuffle: false, repeatMode: .off, favorite: false))
        let store = PlayerModesStore(service: fake, nowPlaying: nowPlaying)
        store.refresh()
        for _ in 0..<100 where store.modes == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(await fake.readTracks == [nil])
    }
}

/// Stands in for CoreAudio.
@MainActor
final class FakeOutputs: AudioOutputsService {
    var onChange: (() -> Void)?
    var devices = [AudioOutput(id: 1, name: "MacBook Air Speakers", kind: .builtInSpeakers),
                   AudioOutput(id: 2, name: "Sam’s AirPods Pro", kind: .airPods)]
    var current: AudioOutput.ID? = 1
    func outputs() -> [AudioOutput] { devices }
    func currentOutput() -> AudioOutput.ID? { current }
    func select(_ id: AudioOutput.ID) -> Bool { current = id; onChange?(); return true }
    func start() {}
}

struct AudioOutputsStoreTests {
    @Test func listsOutputsAndSwitches() {
        let fake = FakeOutputs()
        let store = AudioOutputsStore(service: fake)
        store.start()
        #expect(store.outputs.count == 2)
        #expect(store.current?.name == "MacBook Air Speakers")
        store.select(2)
        #expect(store.current?.kind == .airPods)
        fake.devices.removeLast()          // AirPods disconnect: CoreAudio tells the store
        fake.current = 1
        fake.onChange?()
        #expect(store.outputs.count == 1 && store.current?.id == 1)
    }
}

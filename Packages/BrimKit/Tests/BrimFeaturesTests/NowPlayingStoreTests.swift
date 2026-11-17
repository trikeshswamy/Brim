import AppKit
import Testing
@testable import BrimCore
@testable import BrimFeatures

/// A stand-in for the helper: tests push events and read which commands were sent.
final class FakeNowPlayingService: NowPlayingService {
    let events: AsyncStream<NowPlayingEvent>
    private let continuation: AsyncStream<NowPlayingEvent>.Continuation
    private(set) var performed: [MediaCommand] = []
    private(set) var seeks: [TimeInterval] = []

    init() {
        (events, continuation) = AsyncStream.makeStream(of: NowPlayingEvent.self)
    }

    func start() {}
    func stop() { continuation.finish() }
    func perform(_ command: MediaCommand) async { performed.append(command) }
    func seek(to position: TimeInterval) async { seeks.append(position) }
    private(set) var modeSets: [String] = []
    func setShuffle(_ on: Bool) async { modeSets.append("shuffle \(on)") }
    func setRepeat(_ mode: RepeatMode) async { modeSets.append("repeat \(mode)") }
    private(set) var retries = 0
    func retryNow() { retries += 1 }
}

struct NowPlayingStoreTests {
    private let song = NowPlaying(title: "Mirage", artist: "Ivy Lane", isPlaying: true, duration: 186, elapsed: 10, timestamp: .now)

    private func makeStore() -> (NowPlayingStore, IslandCoordinator) {
        let island = IslandCoordinator()
        return (NowPlayingStore(service: FakeNowPlayingService(), island: island), island)
    }

    /// Browsers ignore macOS's skip-15 command (tested on YouTube in Dia), so ±15 s is a jump to a position.
    @Test func skipButtonsJumpFifteenSeconds() async {
        let fake = FakeNowPlayingService()
        let store = NowPlayingStore(service: fake, island: IslandCoordinator())
        store.handle(.item(NowPlaying(title: "Video", artist: "Site", isPlaying: false, duration: 100, elapsed: 10, timestamp: .now)))
        store.skipForward()
        store.skipBackward()  // from 10 s, −15 stops at the start
        for _ in 0..<50 where fake.seeks.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(fake.seeks.sorted() == [0, 25])
        #expect(fake.performed.isEmpty)
    }

    /// Your pick (2026-10-02, 0.17.4): music never widens the island, like the iPhone's Dynamic Island.
    @Test func musicStartingNeverWidensTheIsland() {
        let (store, island) = makeStore()
        island.setKeepPillVisible(true)
        store.handle(.item(song))
        #expect(store.item == song)
        #expect(store.availability == .ready)
        #expect(island.surface == .compact(.keptMusic))     // just the pill: cover and moving bars

        let (quiet, hidden) = makeStore()                     // "Keep music visible" off, as you have it
        quiet.handle(.item(song))
        #expect(hidden.surface == .hidden)                    // nothing at all
    }

    /// PRD F2: helper unavailable → the pill steps away and the Music tab says why, with Retry (0.14.0).
    @Test func helperDownSaysWhyAndRetries() {
        let fake = FakeNowPlayingService()
        let island = IslandCoordinator()
        let store = NowPlayingStore(service: fake, island: island)
        store.handle(.item(song))
        #expect(store.unavailableReason == nil)
        store.handle(.availability(.unavailable(reason: "The Now Playing helper keeps stopping.")))
        #expect(store.item == nil)                    // what it showed can't be trusted any more
        #expect(store.unavailableReason == "The Now Playing helper keeps stopping.")
        store.retryHelper()
        #expect(fake.retries == 1)
        #expect(store.availability == .starting)
        store.handle(.item(song))                     // it works again
        #expect(store.availability == .ready)
        #expect(store.item == song)
    }

    @Test func hoverShowsMediaThenIdleWhenMusicStops() async {
        let island = IslandCoordinator()
        let store = NowPlayingStore(service: FakeNowPlayingService(), island: island, blankHold: .milliseconds(20))
        store.handle(.item(song))
        island.hoverChanged(true)
        #expect(island.surface == .expanded(.music))
        store.handle(.item(nil))
        for _ in 0..<100 where store.item != nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(island.surface == .expanded(.calendar))
    }

    /// Your report (2026-10-02): the pill still widened on song changes. Players blink between songs (Now Playing
    /// blanks for 0.1–0.4 s, a video pauses for ~0.2 s), and each blink read as music starting again.
    @Test func aPlayerBlinkingBetweenSongsDoesNotWidenThePill() {
        var clock = Date()
        let island = IslandCoordinator(now: { clock })
        island.setKeepPillVisible(true)
        let store = NowPlayingStore(service: FakeNowPlayingService(), island: island)
        store.now = { clock }
        store.handle(.item(song))
        #expect(island.surface == .compact(.keptMusic))     // music starts: just the pill

        var paused = song
        paused.isPlaying = false
        store.handle(.item(paused))                         // a 0.2 s pause blip
        clock += 0.2
        var next = song
        next.title = "Next song"
        store.handle(.item(next))
        #expect(island.surface == .compact(.keptMusic))     // not widened: only the art turns

        store.handle(.item(nil))                            // a 0.15 s blank before the third song
        #expect(store.item == next)                         // the pill doesn't blink away
        #expect(island.surface == .compact(.keptMusic))
        clock += 0.15
        var third = song
        third.title = "Third song"
        store.handle(.item(third))
        #expect(store.item == third)
        #expect(island.surface == .compact(.keptMusic))
    }

    @Test func resumingNeverWidensEither() {
        var clock = Date()
        let island = IslandCoordinator(now: { clock })
        island.setKeepPillVisible(true)
        let store = NowPlayingStore(service: FakeNowPlayingService(), island: island)
        store.now = { clock }
        store.handle(.item(song))
        clock += 5
        island.reevaluate()
        var paused = song
        paused.isPlaying = false
        store.handle(.item(paused))                         // you pause…
        clock += 10
        island.reevaluate()
        store.handle(.item(song))                           // …and play again 10 s later
        #expect(island.surface == .compact(.keptMusic))
    }

    @Test func aBlankThatLastsStillClearsThePill() async {
        let island = IslandCoordinator()
        island.setKeepPillVisible(true)
        let store = NowPlayingStore(service: FakeNowPlayingService(), island: island, blankHold: .milliseconds(20))
        store.handle(.item(song))
        store.handle(.item(nil))                            // the player quit
        #expect(store.item == song)                         // held a moment…
        for _ in 0..<100 where store.item != nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(store.item == nil)                          // …then gone
        #expect(island.media == .none)
    }

    @Test func pausedSongDoesNotPopTheIsland() {
        let (store, island) = makeStore()
        var paused = song
        paused.isPlaying = false
        store.handle(.item(paused))
        #expect(island.surface == .hidden)
    }

    @Test func playPauseFlipsImmediatelyBeforeConfirmation() {
        let (store, _) = makeStore()
        store.handle(.item(song))
        #expect(store.isPlaying)
        store.togglePlayPause()
        #expect(store.isPlaying == false)  // optimistic, before the helper answers
        store.handle(.item(song))          // helper's next event is the truth
        #expect(store.pendingIsPlaying == nil)
    }

    @Test func artworkColourIsPickedOncePerSong() async throws {
        let (store, _) = makeStore()
        var tinted = song
        tinted.artwork = try Self.solidPNG(red: 0.1, green: 0.8, blue: 0.2)  // green art
        store.handle(.item(tinted))
        let tint = try #require(store.artworkTint)
        #expect(abs(tint.hue - 0.36) < 0.05)

        var noArt = song
        noArt.title = "Next song"
        store.handle(.item(noArt))
        #expect(store.artworkTint != nil)  // a new song keeps the last cover a moment, while its own may come
        // 0.5 s later the placeholder (polled: in a full parallel test run the wait can fire a little late).
        for _ in 0..<200 where store.artworkTint != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.artworkTint == nil)  // no art came → white bars
    }

    /// Decision 12: a new song's cover often arrives a moment after its title; the pill flips once, to it.
    @Test func aLateCoverFlipsOnce() async throws {
        let (store, _) = makeStore()
        var first = song
        first.artwork = try Self.solidPNG(red: 0.9, green: 0.1, blue: 0.1)
        store.handle(.item(first))
        let shown = store.artworkVersion
        var second = song
        second.title = "Next song"
        store.handle(.item(second))  // no cover yet
        #expect(store.artworkVersion == shown)
        second.artwork = try Self.solidPNG(red: 0.1, green: 0.1, blue: 0.9)
        store.handle(.item(second))  // its cover, 0.1 s later in real life
        #expect(store.artworkVersion == shown + 1)
        try await Task.sleep(for: .milliseconds(650))
        #expect(store.artworkVersion == shown + 1)  // and no second flip
    }

    /// 0.17.3: while a new song's cover is on its way, the same song again without it (a position update) used to show
    /// the placeholder early, so the pill flipped twice.
    @Test func aRepeatWhileWaitingForTheCoverDoesNotFlip() async throws {
        let (store, _) = makeStore()
        var first = song
        first.artwork = try Self.solidPNG(red: 0.9, green: 0.1, blue: 0.1)
        store.handle(.item(first))
        let shown = store.artworkVersion
        var second = song
        second.title = "Next song"
        store.handle(.item(second))                       // no cover yet: the pill keeps the last one
        second.elapsed = 1
        store.handle(.item(second))                       // the same song again, still without it
        #expect(store.artworkVersion == shown)            // no placeholder yet
        second.artwork = try Self.solidPNG(red: 0.1, green: 0.1, blue: 0.9)
        store.handle(.item(second))                       // its cover
        #expect(store.artworkVersion == shown + 1)        // one flip, to the right cover
        try await Task.sleep(for: .milliseconds(650))
        #expect(store.artworkVersion == shown + 1)
    }

    @Test func theSameCoverDoesNotFlip() throws {
        let (store, _) = makeStore()
        let cover = try Self.solidPNG(red: 0.2, green: 0.6, blue: 0.9)
        var first = song
        first.artwork = cover
        store.handle(.item(first))
        let shown = store.artworkVersion
        var sameAlbum = song
        sameAlbum.title = "Next song"
        sameAlbum.artwork = cover
        store.handle(.item(sameAlbum))
        #expect(store.artworkVersion == shown)
    }

    /// A 32 × 32 PNG of one colour, like the artwork bytes the helper sends.
    private static func solidPNG(red: Double, green: Double, blue: Double) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.representation(using: .png, properties: [:]))
    }
}

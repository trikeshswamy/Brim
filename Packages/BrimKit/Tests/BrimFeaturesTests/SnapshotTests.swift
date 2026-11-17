import AppKit
import SwiftUI
import Testing
@testable import BrimCore
@testable import BrimFeatures

/// Renders the real island views to PNGs for a visual check. Skipped unless you ask for it:
///
///     BRIM_SNAPSHOTS=/path/to/folder swift test --package-path Packages/BrimKit --filter SnapshotTests
///
/// Black renders exactly. Liquid Glass and the waveform (an AppKit view) can't be drawn offscreen,
/// so check those on screen.
struct SnapshotTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    @Test(.enabled(if: folder != nil))
    func renderBlackIslandStates() async throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let defaults = UserDefaults(suiteName: testSuiteName("brim.snapshots"))!
        let settings = IslandSettings(defaults: defaults)
        settings.appearance = IslandAppearance(rawValue: ProcessInfo.processInfo.environment["BRIM_APPEARANCE"] ?? "") ?? .black
        var clock = Date()
        let island = IslandCoordinator(now: { clock })
        let nowPlaying = NowPlayingStore(service: FakeNowPlayingService(), island: island)
        let hud = HUDStore(volume: FakeVolumeService(), island: island)
        // Made-up lines (no real lyrics), timed so line 2 plays at 51 s into the song.
        let madeUp = Lyrics.synced([
            LyricLine(time: 40, text: "The streetlights hum a quiet tune"),
            // Long lines must wrap, not end in "…" (your P-3 test found them cut).
            LyricLine(time: 48, text: "Walking home through the evening light with your name still ringing in my ears"),
            LyricLine(time: 56, text: "counting every window still awake along the avenue tonight"),
        ])
        let lyrics = LyricsStore(service: FakeLyricsService(answer: .found(madeUp)), nowPlaying: nowPlaying)
        lyrics.start()
        let modes = PlayerModesStore(service: FakePlayerControls(PlayerModes(shuffle: true, repeatMode: .off)), nowPlaying: nowPlaying)
        let root = IslandRootView(coordinator: island, nowPlaying: nowPlaying, hud: hud, lyrics: lyrics, modes: modes, settings: settings,
                                  actions: IslandActions(openSettings: {}, quit: {}))

        var song = NowPlaying(title: "Lantern", artist: "Milo Hart", bundleIdentifier: "com.spotify.client",
                              isPlaying: true, duration: 196, elapsed: 51, timestamp: .now)
        song.artwork = try Self.gradientPNG()
        nowPlaying.handle(.item(song))
        island.setKeepPillVisible(true)
        modes.refresh()  // the buttons do this on appear; offscreen rendering doesn't "appear"
        for _ in 0..<100 where modes.modes == nil { try await Task.sleep(for: .milliseconds(10)) }

        func save(_ name: String) throws {
            let view = ZStack(alignment: .top) {
                Color(white: 0.13)  // a dark app toolbar, like your full-screen windows
                root
            }
            .frame(width: IslandMetrics.panelSize.width, height: IslandMetrics.panelSize.height)
            .environment(\.colorScheme, .dark)
            .environment(\.offscreenRender, true)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let rep = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent(name))
        }

        clock = clock.addingTimeInterval(4)  // past the 3 s full pill that a new song shows
        island.setKeptStyle(.slimLine)
        island.reevaluate()
        try save("black-1-slim.png")
        island.setKeptStyle(.pill)
        try save("black-2-pill.png")
        clock = Date()  // HUD activities start now
        hud.handle(.changed(VolumeState(level: 0.62, isMuted: false)))
        try save("black-3-volume.png")
        hud.brightnessChanged(to: 0.3)
        try save("black-4-brightness.png")
        island.hoverChanged(true)
        try save("black-5-open.png")

        // A title too long for the pill: at rest it fades at the cut edge instead of "…".
        island.hoverChanged(false)
        var long = NowPlaying(title: "Kesariya (From \"Brahmastra\")", artist: "Pritam, Arijit Singh, Amitabh Bhattacharya",
                              isPlaying: true, duration: 268, elapsed: 30, timestamp: .now)
        long.artwork = song.artwork
        nowPlaying.handle(.item(long))
        clock = Date().addingTimeInterval(10)  // past the HUD, the hover grace, and the 3 s song pill
        island.reevaluate()
        try save("black-6-long-pill.png")
        island.hoverChanged(true)
        try save("black-7-long-open.png")

        // Lyrics mode (layout A): the current line bright, the next one dim.
        settings.lyricsModeOn = true
        nowPlaying.handle(.item(song))
        // The store follows Now Playing a moment after each change (like in the app); give it that moment.
        for _ in 0..<100 where lyrics.status != .ready { try await Task.sleep(for: .milliseconds(10)) }
        lyrics.beginDisplay()  // the view does this on appear; offscreen rendering doesn't "appear"
        try save("black-8-lyrics.png")
        lyrics.endDisplay()

        // The Now Playing | Today switch (2026-09-30), with no HUD banner over it: a fresh HUD store.
        settings.lyricsModeOn = false
        let quietRoot = IslandRootView(coordinator: island, nowPlaying: nowPlaying, hud: HUDStore(volume: FakeVolumeService(), island: island),
                                       lyrics: lyrics, modes: modes, settings: settings, actions: IslandActions(openSettings: {}, quit: {}))
        func saveQuiet(_ name: String) throws {
            let view = ZStack(alignment: .top) { Color(white: 0.13); quietRoot }
                .frame(width: IslandMetrics.panelSize.width, height: IslandMetrics.panelSize.height)
                .environment(\.colorScheme, .dark)
                .environment(\.offscreenRender, true)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let rep = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent(name))
        }
        try saveQuiet("black-9-switch-now-playing.png")
        island.showPage(.calendar)
        try saveQuiet("black-10-switch-today.png")
    }

    /// Your report (2026-10-02): Spotify 1.3.3 answered none of Brim's Apple Events. Top: Spotify answering. Bottom:
    /// it isn't, while a paused video holds macOS's Now Playing (Brim must talk to Spotify directly): every button that
    /// needs Spotify fades and says why on hover; Shuffle & Repeat stay instead of vanishing.
    @Test(.enabled(if: folder != nil))
    func renderControlsWhenSpotifyDoesntAnswer() async throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        func row(answers: Bool) async throws -> some View {
            let controls = FakePlayerControls(PlayerModes(shuffle: true, repeatMode: .all), answers: answers)
            let nowPlaying = NowPlayingStore(service: FakeNowPlayingService(), island: IslandCoordinator(),
                                             controls: controls, switchDelay: .milliseconds(10))
            nowPlaying.handle(.item(NowPlaying(title: "A video", bundleIdentifier: "company.thebrowser.dia",
                                               isPlaying: false, duration: 600, elapsed: 60, timestamp: .now)))
            nowPlaying.handle(PlayerAnnouncement(player: .spotify, state: .playing, title: "Song", artist: "Artist",
                                                 album: "Album", duration: 200, position: 30, date: .now))
            for _ in 0..<200 where nowPlaying.source != .player(.spotify) { try await Task.sleep(for: .milliseconds(10)) }
            let modes = PlayerModesStore(service: controls, nowPlaying: nowPlaying)
            modes.refresh()
            for _ in 0..<200 where modes.modes == nil && !modes.unreachable { try await Task.sleep(for: .milliseconds(10)) }
            return TransportRow(store: nowPlaying, modes: modes, sideButtons: .shuffleRepeat)
        }
        let answering = try await row(answers: true)
        let silent = try await row(answers: false)
        let sheet = VStack(spacing: 18) {
            answering
            silent
        }
        .padding(20)
        .frame(width: 420)
        .background(Color(white: 0.1))
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent("controls-unreachable.png"))
    }

    @Test(.enabled(if: folder != nil))
    func renderFullScreenPlayer() async throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let nowPlaying = NowPlayingStore(service: FakeNowPlayingService(), island: IslandCoordinator())
        var song = NowPlaying(title: "Lantern", artist: "Milo Hart", bundleIdentifier: "com.apple.Music",
                              isPlaying: true, duration: 196, elapsed: 51, timestamp: .now)
        song.artwork = try Self.gradientPNG()
        // Made-up lines (no real lyrics); at 51 s the third line is playing.
        let madeUp = Lyrics.synced([
            LyricLine(time: 30, text: "Somewhere past the station clock"),
            LyricLine(time: 40, text: "The streetlights hum a quiet tune"),
            // Long lines must wrap, not end in "…" (your P-3 test found them cut).
            LyricLine(time: 48, text: "Walking home through the evening light with your name still ringing in my ears"),
            LyricLine(time: 56, text: "counting every window still awake along the avenue tonight"),
            LyricLine(time: 63, text: "and every one of them is you"),
            LyricLine(time: 70, text: ""),
            LyricLine(time: 78, text: "So I keep on walking"),
        ])
        let lyrics = LyricsStore(service: FakeLyricsService(answer: .found(madeUp)), nowPlaying: nowPlaying)
        lyrics.start()
        nowPlaying.handle(.item(song))
        for _ in 0..<100 where lyrics.status != .ready { try await Task.sleep(for: .milliseconds(10)) }
        lyrics.beginDisplay()

        let settings = IslandSettings(defaults: UserDefaults(suiteName: testSuiteName("brim.snapshots"))!)
        let hud = HUDStore(volume: FakeVolumeService(), island: IslandCoordinator())
        hud.handle(.baseline(VolumeState(level: 0.6, isMuted: false)))
        let modes = PlayerModesStore(service: FakePlayerControls(PlayerModes(shuffle: true, repeatMode: .one)), nowPlaying: nowPlaying)
        modes.refresh()
        for _ in 0..<100 where modes.modes == nil { try await Task.sleep(for: .milliseconds(10)) }
        let view = FullScreenPlayerView(nowPlaying: nowPlaying, lyrics: lyrics, hud: hud, modes: modes, settings: settings,
                                        actions: FullScreenActions(close: {}))
            .frame(width: 1440, height: 900)
            .environment(\.offscreenRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent("fullscreen-1.png"))
        lyrics.endDisplay()
    }

    /// Pink-to-purple art, like the mockups.
    private static func gradientPNG() throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: NSColor(srgbRed: 0.93, green: 0.42, blue: 0.62, alpha: 1),
                   ending: NSColor(srgbRed: 0.36, green: 0.24, blue: 0.72, alpha: 1))?
            .draw(in: NSRect(x: 0, y: 0, width: 64, height: 64), angle: -45)
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.representation(using: .png, properties: [:]))
    }
}

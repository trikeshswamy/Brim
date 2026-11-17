import AppKit
import SwiftUI
import Testing
@testable import BrimCore
@testable import BrimFeatures

/// Brim's face outside the welcome (2026-11-11), drawn by the real views: asleep in the resting pill (Notch and Black
/// Pill), awake under the hand-off's dimmed screen and arrow, and a tip under the open island.
/// `BRIM_SNAPSHOTS=<folder> swift test --filter MascotMockupTests` writes mascot-mockups.png.
@MainActor
struct MascotMockupTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    /// The island as the app builds it, with made-up music when `playing`.
    private struct Rig {
        let island = IslandCoordinator()
        let settings: IslandSettings
        let tips: TipsStore
        let nowPlaying: NowPlayingStore
        let root: IslandRootView

        init(look: IslandAppearance, playing: Bool) throws {
            settings = IslandSettings(defaults: UserDefaults(suiteName: testSuiteName("brim.mascot"))!)
            settings.appearance = look
            tips = TipsStore(settings: settings, delay: .zero, dwell: .seconds(60))
            nowPlaying = NowPlayingStore(service: FakeNowPlayingService(), island: island)
            let hud = HUDStore(volume: FakeVolumeService(), island: island)
            let lyrics = LyricsStore(service: FakeLyricsService(answer: .notFound), nowPlaying: nowPlaying)
            let modes = PlayerModesStore(service: FakePlayerControls(PlayerModes(shuffle: false, repeatMode: .off)),
                                         nowPlaying: nowPlaying)
            root = IslandRootView(coordinator: island, nowPlaying: nowPlaying, hud: hud, lyrics: lyrics, modes: modes,
                                  settings: settings, actions: IslandActions(openSettings: {}, quit: {}), tips: tips)
            island.setIdleStyle(.asleep)
            if playing {
                var song = NowPlaying(title: "Lantern", artist: "Milo Hart", bundleIdentifier: "com.spotify.client",
                                      isPlaying: true, duration: 196, elapsed: 51, timestamp: .now)
                song.artwork = try MascotMockupTests.gradientPNG()
                nowPlaying.handle(.item(song))
                island.setKeepPillVisible(true)
            }
        }
    }

    @Test(.enabled(if: folder != nil)) func renderMascotMockups() async throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let asleepNotch = try Rig(look: .black, playing: false)
        let asleepPill = try Rig(look: .blackPill, playing: false)
        let pointedAt = try Rig(look: .blackPill, playing: false)
        pointedAt.island.spotlit = true
        let model = HandoffModel()
        model.showing = true
        let tipped = try Rig(look: .black, playing: true)
        tipped.island.hoverChanged(true)
        tipped.tips.islandOpened { TipsStore.Showing(page: .music, hasSong: true, lyricsShowing: false) }
        for _ in 0..<50 where tipped.tips.current == nil { await Task.yield() }
        let covered = try Rig(look: .black, playing: true)
        covered.settings.tipsSeen = ["menu"]
        covered.island.hoverChanged(true)
        covered.tips.islandOpened { TipsStore.Showing(page: .music, hasSong: true, lyricsShowing: false) }
        for _ in 0..<50 where covered.tips.current == nil { await Task.yield() }

        let bottom = IslandMetrics.topGap(for: .compact(.keptMusic), appearance: .blackPill)
            + IslandMetrics.pillSize(appearance: .blackPill).height
        let sheet = VStack(alignment: .leading, spacing: 18) {
            Text("Brim's face outside the welcome · the real views")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            HStack(alignment: .top, spacing: 16) {
                Screen(label: "Nothing plays · Notch: Brim asleep") { asleepNotch.root }
                Screen(label: "Nothing plays · Black Pill: Brim asleep") { asleepPill.root }
            }
            HStack(alignment: .top, spacing: 16) {
                Screen(label: "After Done: the screen dims, the arrow points, Brim's eyes open") {
                    ZStack(alignment: .top) {
                        HandoffView(model: model, islandBottom: bottom)
                        pointedAt.root
                    }
                }
                Screen(label: "First time you open Brim: a tip peeks out") { tipped.root }
            }
            HStack(alignment: .top, spacing: 16) {
                Screen(label: "Next opening, with a song: the next tip") { covered.root }
                Color.clear.frame(width: 460, height: 10)
            }
        }
        .padding(28)
        .background(Color(white: 0.09))
        .environment(\.offscreenRender, true)
        .environment(\.colorScheme, .dark)
        .compositingGroup()
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent("mascot-mockups.png"))
    }

    /// Pink-to-purple art, like the other mockups.
    static func gradientPNG() throws -> Data {
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

/// The top of a Mac's screen: a wallpaper with the island's own window on it.
private struct Screen: View {
    let label: String
    let content: AnyView
    init(label: String, @ViewBuilder content: () -> some View) {
        self.label = label
        self.content = AnyView(content())
    }
    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.2, green: 0.32, blue: 0.55), Color(red: 0.5, green: 0.3, blue: 0.5)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                content.frame(width: IslandMetrics.panelSize.width, height: IslandMetrics.panelSize.height)
            }
            .frame(width: IslandMetrics.panelSize.width, height: IslandMetrics.panelSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
        }
    }
}

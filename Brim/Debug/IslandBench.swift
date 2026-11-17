#if DEBUG
import AppKit
import SwiftUI
import os
import BrimCore
import BrimFeatures

/// Debug-only: `--island-bench <dir>` draws the island in a window in the screen's bottom-left corner with a made-up
/// song, keep-awake on (asking macOS for nothing) and a 10-minute timer (ringing nowhere), all on its own settings.
/// It switches the appearance (Glass → Black → Glass → Black) and saves pictures of the window, ~36 a
/// second, into `<dir>`, also swiping a bubble away and back in each look. For your 0.13.3 test: after switching,
/// the Live Activities were gone (two stacked transitions put them twice as far out). Your real settings,
/// timers and keep-awake are never touched. Never in release builds.
@MainActor
enum IslandBench {
    private static var window: NSWindow?
    private static var stores: [AnyObject] = []

    static func startIfRequested(environment env: AppEnvironment) {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--helper-down-bench"), flag + 1 < args.count {
            helperDownBench(environment: env, into: URL(fileURLWithPath: args[flag + 1]))
            return
        }
        if let flag = args.firstIndex(of: "--flip-bench"), flag + 1 < args.count {
            flipBench(environment: env, into: URL(fileURLWithPath: args[flag + 1]))
            return
        }
        if let flag = args.firstIndex(of: "--marquee-check"), flag + 1 < args.count {
            marqueeCheck(into: URL(fileURLWithPath: args[flag + 1]), capture: !args.contains("--no-capture"))
            return
        }
        if let flag = args.firstIndex(of: "--pill-mockup"), flag + 1 < args.count {
            // Waits 2 s so the real song's artwork has arrived (a made-up cover if nothing plays).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                pillMockup(environment: env, into: URL(fileURLWithPath: args[flag + 1]))
            }
            return
        }
        guard let flag = args.firstIndex(of: "--island-bench"), flag + 1 < args.count else { return }
        let suite = "com.theojones.Brim.island-bench"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defaults.removePersistentDomain(forName: suite)  // a fresh start every run
        let settings = IslandSettings(defaults: defaults)
        let island = IslandCoordinator()
        let nowPlaying = NowPlayingStore(service: BenchNowPlaying(), island: island)
        let lyrics = LyricsStore(service: BenchLyrics(), nowPlaying: nowPlaying)
        let modes = PlayerModesStore(service: env.playerControls, nowPlaying: nowPlaying)
        let timer = TimerStore(island: island, alarm: SilentAlarm(), defaults: defaults)
        let keepAwake = KeepAwakeStore(service: NoAssertion(), island: island)
        stores = [settings, island, nowPlaying, lyrics, modes, timer, keepAwake]
        island.setKeepPillVisible(settings.keepPillVisible)
        island.setKeptStyle(settings.keptStyle)
        nowPlaying.start()
        timer.start()
        timer.start(length: 600)
        keepAwake.start(minutes: nil)

        let size = IslandMetrics.panelSize
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let window = NSWindow(contentRect: NSRect(x: screen.minX + 20, y: screen.minY + 20, width: size.width, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: ZStack(alignment: .top) {
            // Something like a desktop behind it, so glass has something to show.
            LinearGradient(colors: [Color(red: 0.25, green: 0.35, blue: 0.55), Color(red: 0.55, green: 0.4, blue: 0.3)],
                           startPoint: .leading, endPoint: .trailing)
            IslandRootView(coordinator: island, nowPlaying: nowPlaying, hud: env.hud, lyrics: lyrics, modes: modes,
                           settings: settings, actions: IslandActions(openSettings: {}, quit: {}), timer: timer,
                           keepAwake: keepAwake)
                .frame(width: size.width, height: size.height, alignment: .top)
        }
        .frame(width: size.width, height: 120, alignment: .top)
        .clipped())
        window.orderFrontRegardless()
        self.window = window

        func report(_ step: String) {
            let sides = IslandSides.current(surface: island.surface, timer: timer, calendar: nil, keepAwake: keepAwake.isOn,
                                            hiding: island.hiddenBubbles)
            Log.app.notice("Island bench: \(step, privacy: .public) · surface \(String(describing: island.surface), privacy: .public) · \(settings.appearance.rawValue, privacy: .public) · left \(sides.left, privacy: .public) right \(sides.right != nil, privacy: .public) · hidden \(island.hiddenBubbles.count, privacy: .public)")
        }
        // Your actions, in both looks: swipe a bubble away, bring it back, switch the look (Glass first).
        func swipeAway(_ side: BubbleSide?) {
            _ = island.swipe(on: side, available: IslandSides.current(surface: island.surface, timer: timer, calendar: nil,
                                                                      keepAwake: keepAwake.isOn))
        }
        let steps: [(Double, String, () -> Void)] = [
            (4.5, "glass: swipe left away", { swipeAway(.left) }),
            (5.5, "glass: bring back", { island.showBubbles() }),
            (6.5, "to black", { settings.appearance = .black }),
            (7.5, "black: swipe right away", { swipeAway(.right) }),
            (8.5, "black: bring back", { island.showBubbles() }),
            (9.5, "to glass", { settings.appearance = .liquidGlass }),
            (10.5, "to black", { settings.appearance = .black }),
            (11.3, "pill swipe: all hide", { swipeAway(nil) }),
            (12.3, "pill swipe: all back", { swipeAway(nil) }),
        ]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { report("start") }
        for (at, name, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                action()
                report(name)
            }
        }
        LyricsBench.captureFrames(of: window, into: URL(fileURLWithPath: args[flag + 1]), from: 1, for: 12.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
            keepAwake.stop()
            timer.cancelAll()
            window.orderOut(nil)
            self.window = nil
            stores = []
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

extension IslandBench {
    /// `--pill-mockup <dir>`: the kept pill's artwork at three sizes in both looks (PillArtMockup), in a corner window
    /// over a desktop-like gradient, captured into `<dir>`, then closed (~4 s). Your settings are never touched.
    static func pillMockup(environment env: AppEnvironment, into folder: URL) {
        let island = IslandCoordinator()
        let cover = env.nowPlaying.artwork ?? madeUpCover()
        let data = cover.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        let store = NowPlayingStore(service: MockupNowPlaying(artwork: data), island: island)
        store.start()
        stores = [island, store]
        let size = NSSize(width: 720, height: 210)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: screen.minX + 20, y: screen.minY + 20), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: ZStack {
            LinearGradient(colors: [Color(red: 0.25, green: 0.35, blue: 0.55), Color(red: 0.55, green: 0.4, blue: 0.3)],
                           startPoint: .leading, endPoint: .trailing)
            PillArtMockup(store: store)
        }
        .frame(width: size.width, height: size.height))
        window.orderFrontRegardless()
        self.window = window
        LyricsBench.captureFrames(of: window, into: folder, from: 1.5, for: 0.4, retina: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            window.orderOut(nil)
            self.window = nil
            stores = []
        }
    }

    /// `--marquee-check <dir>` (2026-10-29): the looping marquee at the full-screen sizes (MarqueeMockup) in a small
    /// corner window; a frame every 0.25 s for 14 s into `<dir>` (light on purpose), then Brim quits at 25 s.
    /// `--no-capture`: the window only, to measure what the loop itself costs.
    static func marqueeCheck(into folder: URL, capture: Bool) {
        let size = NSSize(width: 480, height: 110)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: screen.minX + 20, y: screen.minY + 20), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: MarqueeMockup().frame(width: size.width, height: size.height))
        window.orderFrontRegardless()
        self.window = window
        if capture {
            typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            if let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") {
                let create = unsafeBitCast(symbol, to: CreateImage.self)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let id = UInt32(window.windowNumber)
                Task { @MainActor in
                    let began = Date()
                    while Date().timeIntervalSince(began) < 14 {
                        if let image = create(.null, 8, id, 1 | 16)?.takeRetainedValue() {
                            let name = String(format: "m%06.2f.png", Date().timeIntervalSince(began))
                            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                                .write(to: folder.appendingPathComponent(name))
                        }
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { NSApp.terminate(nil) }
    }

    /// `--flip-bench <dir>` (decision 12): the Glass pill playing song A; at 4.5 s song B, whose cover comes 0.15 s
    /// later (one flip, to it); at 6.5 s song C, whose cover never comes (a flip to the placeholder after 0.5 s).
    /// Captures the pill and logs the island's state after each change: it should never widen. ~9 s, own settings.
    static func flipBench(environment env: AppEnvironment, into folder: URL) {
        let suite = "com.theojones.Brim.flip-bench"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defaults.removePersistentDomain(forName: suite)
        let settings = IslandSettings(defaults: defaults)
        let island = IslandCoordinator()
        let songs = ScriptedNowPlaying()
        let nowPlaying = NowPlayingStore(service: songs, island: island)
        let lyrics = LyricsStore(service: BenchLyrics(), nowPlaying: nowPlaying)
        let modes = PlayerModesStore(service: env.playerControls, nowPlaying: nowPlaying)
        stores = [settings, island, songs, nowPlaying, lyrics, modes]
        island.setKeepPillVisible(true)
        island.setKeptStyle(settings.keptStyle)
        nowPlaying.start()
        let size = IslandMetrics.panelSize
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let window = NSWindow(contentRect: NSRect(x: screen.minX + 20, y: screen.minY + 20, width: size.width, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.25, green: 0.35, blue: 0.55), Color(red: 0.55, green: 0.4, blue: 0.3)],
                           startPoint: .leading, endPoint: .trailing)
            IslandRootView(coordinator: island, nowPlaying: nowPlaying, hud: env.hud, lyrics: lyrics, modes: modes,
                           settings: settings, actions: IslandActions(openSettings: {}, quit: {}))
                .frame(width: size.width, height: size.height, alignment: .top)
        }
        .frame(width: size.width, height: 80, alignment: .top)
        .clipped())
        window.orderFrontRegardless()
        self.window = window
        func cover(_ a: NSColor, _ b: NSColor) -> Data? {
            madeUpCover(a, b).tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        }
        func song(_ title: String, _ art: Data?) -> NowPlaying {
            NowPlaying(title: title, artist: "Brim", isPlaying: true, duration: 200, elapsed: 0, timestamp: .now,
                       playbackRate: 1, artwork: art)
        }
        func report(_ step: String) {
            Log.app.notice("Flip bench: \(step, privacy: .public) · surface \(String(describing: island.surface), privacy: .public) · cover version \(nowPlaying.artworkVersion, privacy: .public)")
        }
        let b = cover(.systemTeal, .systemBlue)
        let steps: [(Double, String, () -> Void)] = [
            (0.3, "A starts", { songs.send(song("Song A", cover(.systemPink, .systemIndigo))) }),
            (4.5, "B, no cover yet", { songs.send(song("Song B", nil)) }),
            (4.65, "B's cover", { songs.send(song("Song B", b)) }),
            (6.5, "C, no cover ever", { songs.send(song("Song C", nil)) }),
        ]
        for (at, name, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { action(); report(name) }
            DispatchQueue.main.asyncAfter(deadline: .now() + at + 0.3) { report(name + " +0.3 s") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.3) { report("C +0.8 s") }
        LyricsBench.captureFrames(of: window, into: folder, from: 3.8, for: 4, retina: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
            window.orderOut(nil)
            self.window = nil
            stores = []
            defaults.removePersistentDomain(forName: suite)
        }
    }

    /// `--helper-down-bench <dir>`: the open island's Music tab while the Now Playing helper keeps stopping (the message
    /// and Retry), in both looks, captured at 2x. ~5 s, own settings.
    static func helperDownBench(environment env: AppEnvironment, into folder: URL) {
        let suite = "com.theojones.Brim.helper-down-bench"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defaults.removePersistentDomain(forName: suite)
        let settings = IslandSettings(defaults: defaults)
        let island = IslandCoordinator()
        let songs = ScriptedNowPlaying()
        let nowPlaying = NowPlayingStore(service: songs, island: island)
        let lyrics = LyricsStore(service: BenchLyrics(), nowPlaying: nowPlaying)
        let modes = PlayerModesStore(service: env.playerControls, nowPlaying: nowPlaying)
        stores = [settings, island, songs, nowPlaying, lyrics, modes]
        nowPlaying.start()
        let size = IslandMetrics.panelSize
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let window = NSWindow(contentRect: NSRect(x: screen.minX + 20, y: screen.minY + 20, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.25, green: 0.35, blue: 0.55), Color(red: 0.55, green: 0.4, blue: 0.3)],
                           startPoint: .leading, endPoint: .trailing)
            IslandRootView(coordinator: island, nowPlaying: nowPlaying, hud: env.hud, lyrics: lyrics, modes: modes,
                           settings: settings, actions: IslandActions(openSettings: {}, quit: {}))
        }
        .frame(width: size.width, height: size.height, alignment: .top))
        window.orderFrontRegardless()
        self.window = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            songs.announce(.unavailable(reason: "The Now Playing helper keeps stopping. Brim will keep retrying."))
            island.open(page: .music)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { settings.appearance = .black }
        LyricsBench.captureFrames(of: window, into: folder, from: 1.8, for: 1.6, retina: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            window.orderOut(nil)
            self.window = nil
            stores = []
            defaults.removePersistentDomain(forName: suite)
        }
    }

    /// A stand-in cover: a soft gradient with a circle.
    private static func madeUpCover(_ from: NSColor = .systemPink, _ to: NSColor = .systemIndigo) -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            NSGradient(colors: [from, to])?.draw(in: rect, angle: 45)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 90, dy: 90)).fill()
            return true
        }
    }
}

/// Sends whatever song the bench says, when it says.
private final class ScriptedNowPlaying: NowPlayingService {
    let events: AsyncStream<NowPlayingEvent>
    private let continuation: AsyncStream<NowPlayingEvent>.Continuation

    init() { (events, continuation) = AsyncStream.makeStream(of: NowPlayingEvent.self) }

    func send(_ item: NowPlaying?) { continuation.yield(.item(item)) }
    func announce(_ availability: Availability) { continuation.yield(.availability(availability)) }
    func start() { continuation.yield(.availability(.ready)) }
    func stop() { continuation.finish() }
    func perform(_ command: MediaCommand) async {}
    func seek(to position: TimeInterval) async {}
    func setShuffle(_ on: Bool) async {}
    func setRepeat(_ mode: RepeatMode) async {}
}

/// One song, playing, with the given cover.
private final class MockupNowPlaying: NowPlayingService {
    let events: AsyncStream<NowPlayingEvent>
    private let continuation: AsyncStream<NowPlayingEvent>.Continuation
    private let artwork: Data?

    init(artwork: Data?) {
        self.artwork = artwork
        (events, continuation) = AsyncStream.makeStream(of: NowPlayingEvent.self)
    }

    func start() {
        continuation.yield(.availability(.ready))
        continuation.yield(.item(NowPlaying(title: "Mockup", artist: "Brim", isPlaying: true, duration: 200, elapsed: 0,
                                            timestamp: .now, playbackRate: 1, artwork: artwork)))
    }
    func stop() { continuation.finish() }
    func perform(_ command: MediaCommand) async {}
    func seek(to position: TimeInterval) async {}
    func setShuffle(_ on: Bool) async {}
    func setRepeat(_ mode: RepeatMode) async {}
}

private final class SilentAlarm: TimerAlarm {
    func prepare() {}
    func ring(title: String, body: String) {}
    func silence() {}
}

private final class NoAssertion: KeepAwakeService {
    func setAwake(_ on: Bool) -> Bool { true }
}
#endif

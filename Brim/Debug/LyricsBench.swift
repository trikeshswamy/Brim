#if DEBUG
import AppKit
import SwiftUI
import os
import BrimCore
import BrimFeatures

/// Debug-only: `--lyrics-bench` opens the full-screen player on a made-up song whose lines change every
/// 2.5 s (some long enough to wrap), whatever you're really playing. It makes CPU measurements of the lyrics
/// motion and the word sweep repeatable (`top -pid $(pgrep -x Brim)`). Never in release builds.
@MainActor
enum LyricsBench {
    private static var controller: FullScreenPlayerController?

    static func startIfRequested(environment env: AppEnvironment) {
        guard CommandLine.arguments.contains("--lyrics-bench") else { return }
        let island = IslandCoordinator()
        let nowPlaying = NowPlayingStore(service: BenchNowPlaying(), island: island)
        let lyrics = LyricsStore(service: BenchLyrics(), nowPlaying: nowPlaying)
        let modes = PlayerModesStore(service: env.playerControls, nowPlaying: nowPlaying)
        nowPlaying.start()
        lyrics.start()
        // Proof the lines really change: one line per switch in /tmp-free scratch (the build folder).
        let log = URL(fileURLWithPath: CommandLine.arguments.first { $0.hasSuffix(".benchlog") } ?? "/dev/null")
        let started = Date()
        lyrics.onLineSwitch = { lineTime, position in
            let line = String(format: "%.2f line %.1f at %.2f\n", Date().timeIntervalSince(started), lineTime, position)
            if let handle = try? FileHandle(forWritingTo: log) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
            else { try? line.write(to: log, atomically: true, encoding: .utf8) }
        }
        let args = CommandLine.arguments
        // `--bench-nudge <seconds>`: at 2 s, the same clicks as right-click → Lyrics 0.25 s Earlier / Later (a negative
        // number is earlier), so the log shows whether the next line really switches that much sooner or later.
        if let flag = args.firstIndex(of: "--bench-nudge"), flag + 1 < args.count, let total = Double(args[flag + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                for _ in 0..<Int((abs(total) / 0.25).rounded()) { lyrics.nudge(by: total < 0 ? -0.25 : 0.25) }
                let line = String(format: "%.2f nudged to %.2f s\n", Date().timeIntervalSince(started), lyrics.timingOffset)
                if let handle = try? FileHandle(forWritingTo: log) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
            }
        }
        if args.contains("--bench-window") {
            // `--bench-window`: the same player in a small window in the screen's bottom-left corner, never taking the
            // screen or the keyboard (for motion checks while you keep working), plus a control square whose
            // animation is known to work, measured the same way.
            // `--bench-size 1920x1080`: the player at another screen's size (a TV's), from the screen's corner.
            let screen = NSScreen.main?.visibleFrame ?? .zero
            let asked = args.firstIndex(of: "--bench-size").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }?
                .split(separator: "x").compactMap { Double($0) }
            let size = asked?.count == 2 ? CGSize(width: asked![0], height: asked![1]) : CGSize(width: 900, height: 520)
            let inset: CGFloat = asked?.count == 2 ? 0 : 20
            let window = NSWindow(contentRect: NSRect(x: screen.minX + inset, y: screen.minY + inset,
                                                      width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = .floating
            // `--bench-sweep`: the word sweep on in the bench only (its own settings), whatever yours say.
            var settings = env.islandSettings
            if args.contains("--bench-sweep"), let defaults = UserDefaults(suiteName: "com.theojones.Brim.lyrics-bench") {
                defaults.removePersistentDomain(forName: "com.theojones.Brim.lyrics-bench")
                settings = IslandSettings(defaults: defaults)
                settings.lyricsSweep = true
                benchSettings = settings
            }
            window.contentView = NSHostingView(rootView: ZStack(alignment: .topLeading) {
                FullScreenPlayerView(nowPlaying: nowPlaying, lyrics: lyrics, hud: env.hud, modes: modes,
                                     settings: settings, actions: FullScreenActions(close: {}))
                MotionControl()
            })
            window.orderFrontRegardless()
            benchWindow = window
            let seconds = args.firstIndex(of: "--bench-seconds").flatMap { args.count > $0 + 1 ? Double(args[$0 + 1]) : nil } ?? 8
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { benchWindow?.orderOut(nil) }
            if let flag = args.firstIndex(of: "--bench-capture"), flag + 1 < args.count {
                // The whole run, so several line changes (short, long, short) are in the pictures.
                captureFrames(of: window, into: URL(fileURLWithPath: args[flag + 1]), from: 0.5, for: seconds - 0.5)
            }
            return
        }
        let controller = FullScreenPlayerController(coordinator: island, playPause: {}, next: {}, back: {}) { actions in
            FullScreenPlayerView(nowPlaying: nowPlaying, lyrics: lyrics, hud: env.hud, modes: modes,
                                 settings: env.islandSettings, actions: actions)
        }
        self.controller = controller
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { controller.open() }
        // `--bench-seconds N`: closes the player by itself after N s (short, repeatable runs).
        if let flag = args.firstIndex(of: "--bench-seconds"), flag + 1 < args.count, let seconds = Double(args[flag + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 + seconds) { controller.close() }
        }
    }

    private static var benchWindow: NSWindow?
    private static var benchSettings: IslandSettings?

    /// `--bench-capture <dir>`: pictures of Brim's own bench window, as often as the Mac allows (~28 a second), so the
    /// lyrics motion can be measured frame by frame without a screen recording or any probe inside the view (a probe
    /// that reads the view's state can hide a bug: it did, 2026-10-01). Uses CoreGraphics' own-window capture (hidden
    /// from the SDK since macOS 15, looked up at run time; debug only).
    static func captureFrames(of window: NSWindow, into folder: URL, from start: Double, for duration: Double,
                              retina: Bool = false) {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else {
            Log.app.notice("Bench capture: no CGWindowListCreateImage")
            return
        }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let windowID = UInt32(window.windowNumber)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(start))
            let began = Date()
            var index = 0
            while Date().timeIntervalSince(began) < duration {
                // Including only this window (8), its bounds without the frame (1), at 1x (16) unless `retina`.
                if let image = create(.null, 8, windowID, retina ? 1 : 1 | 16)?.takeRetainedValue() {
                    let rep = NSBitmapImageRep(cgImage: image)
                    let name = String(format: "c%04d_%07.3f.png", index, Date().timeIntervalSince(began))
                    try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name))
                    index += 1
                }
                try? await Task.sleep(for: .milliseconds(12))
            }
            Log.app.notice("Bench capture: \(index, privacy: .public) frames")
        }
    }
}

/// Three green squares in the corner that drop every 1.25 s, each 0.15 s after the one before, on plain
/// `.animation(_:value:)` springs: the known-good motion in the captured pictures. They proved per-view delays work
/// (2026-10-01), which pointed at LyricRow's own fade as the thing keeping the lyrics in lockstep.
private struct MotionControl: View {
    @State private var down = false

    var body: some View {
        // Three squares on the same spring, each 0.15 s after the one before (does a per-view delay work?).
        HStack(alignment: .top, spacing: 10) {
            ForEach(0..<3, id: \.self) { index in
                Rectangle().fill(Color.green).frame(width: 20, height: 20)
                    .offset(y: down ? 60 : 0)
                    .animation(.spring(response: 0.4, dampingFraction: 1).delay(Double(index) * 0.15), value: down)
            }
        }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1.25))
                    down.toggle()
                }
            }
    }
}

/// One song, playing from the start, 200 s long (also the island bench's).
final class BenchNowPlaying: NowPlayingService {
    let events: AsyncStream<NowPlayingEvent>
    private let continuation: AsyncStream<NowPlayingEvent>.Continuation

    init() { (events, continuation) = AsyncStream.makeStream(of: NowPlayingEvent.self) }

    func start() {
        continuation.yield(.availability(.ready))
        continuation.yield(.item(NowPlaying(title: "Bench Song", artist: "Brim", album: "Bench", isPlaying: true,
                                            duration: 200, elapsed: 0, timestamp: .now, playbackRate: 1)))
    }
    func stop() { continuation.finish() }
    func perform(_ command: MediaCommand) async {}
    func seek(to position: TimeInterval) async {}
    func setShuffle(_ on: Bool) async {}
    func setRepeat(_ mode: RepeatMode) async {}
}

/// Made-up lines every 2.5 s from 1 s; every third one long enough to wrap.
actor BenchLyrics: LyricsService {
    func lyrics(for query: LyricsQuery) async -> LyricsResult {
        let short = "walking home under the evening light"
        let long = "counting every window still awake along the avenue while the city hums a quiet tune"
        return .found(.synced((0..<76).map { LyricLine(time: 1 + Double($0) * 2.5, text: $0 % 3 == 2 ? long : short) }))
    }
    func offset(for query: LyricsQuery) async -> TimeInterval { 0 }
    func setOffset(_ offset: TimeInterval, for query: LyricsQuery) async {}
    func versions(for query: LyricsQuery) async -> LyricsVersionsResult { .failed("bench") }
    func use(_ version: LyricsVersion, for query: LyricsQuery) async {}
}
#endif

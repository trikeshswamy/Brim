#if DEBUG
import AppKit
import AVFoundation
import SwiftUI
import os
import BrimCore
import BrimFeatures

/// Debug-only: `--site-capture <dir>` records the site's videos from the real Brim (your pick, 2026-11-11: real
/// footage, no drawn imitations). It plays scripted scenes of the real views, with their real animations, in a
/// window in the screen's bottom-left corner, over a made-up wallpaper, and writes .mp4 files into `<dir>`:
/// `<dir>/<look>/<scene>.mp4` for each look (notch, glass, pill), plus `<dir>/welcome.mp4`.
///
/// A drawn pointer shows what you'd do (it glides, and a ring marks each click), and the picture zooms in on the
/// action and back out, like a screen-recording tool would (your ask, 2026-11-11). The pointer is only a picture:
/// your real pointer is never moved, and what it "clicks" is done by the script.
///
/// `--songs real`: the last four songs in Brim's History, with their covers from Apple's public catalog
/// (itunes.apple.com), and the next ones as Up Next. Without it: made-up songs with covers drawn here.
/// Lyric lines are always made up (lyrics are the songwriters', and never go into a recording), so wherever lyrics
/// show (the `lyrics` and `player` scenes) the song is a made-up one too: its title and its words then belong
/// together. The meeting is always made up.
/// It runs on its own settings and fake services: your settings, timers, calendar, volume and music are never
/// touched, and nothing is asked of macOS. Brim quits when it's done. `--scene <name>` and `--look <name>` record
/// just one. Never in release builds.
@MainActor
enum SiteCapture {
    private static var window: NSWindow?
    private static var keep: [AnyObject] = []
    private static var menus: (pill: [DrawnMenuItem], awake: [DrawnMenuItem]) = ([], [])

    static func startIfRequested(environment env: AppEnvironment) {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--site-capture"), flag + 1 < args.count else { return }
        func value(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let folder = URL(fileURLWithPath: args[flag + 1])
        let onlyScene = value("--scene"), onlyLook = value("--look")
        let real = value("--songs") == "real"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))  // let the app settle first
            let songs = real ? await SongBook.fromHistory(env.history) : SongBook.madeUp
            // The menus in the `awake` and `menu` scenes: Brim's real items (titles, order, checkmarks, submenus), read
            // from the app's own builders. macOS menus open in their own windows and hold the app while open, so they
            // can't be recorded from inside Brim; they're drawn from these (your ask, 2026-11-14).
            menus = (pill: DrawnMenuItem.items(of: env.makePillMenu()), awake: DrawnMenuItem.items(of: env.makeKeepAwakeMenu()))
            Log.app.notice("Site capture: \(songs.main.count, privacy: .public) songs, \(songs.queue.count, privacy: .public) up next, real: \(real, privacy: .public)")
            for look in Look.allCases where onlyLook == nil || onlyLook == look.rawValue {
                for scene in Scene.perLook where onlyScene == nil || onlyScene == scene.rawValue {
                    await record(scene, look: look.appearance, songs: songs, into: folder.appendingPathComponent(look.rawValue))
                }
            }
            if onlyLook == nil {
                for scene in Scene.once where onlyScene == nil || onlyScene == scene.rawValue {
                    await record(scene, look: .black, songs: songs, into: folder)
                }
            }
            Log.app.notice("Site capture: done")
            NSApp.terminate(nil)
        }
    }

    enum Look: String, CaseIterable {
        case notch, glass, pill
        var appearance: IslandAppearance {
            switch self {
            case .notch: .black
            case .glass: .liquidGlass
            case .pill: .blackPill
            }
        }
    }

    enum Scene: String {
        case open, lyrics, meeting, timer, volume, asleep, player, welcome
        /// Your site plan (2026-11-14): click the coffee; two-finger click the pill for a timer; click the app's icon.
        case awake, menu, app
        /// Recorded in each look.
        static let perLook: [Scene] = [.open, .lyrics, .meeting, .timer, .volume, .asleep, .player, .awake, .menu, .app]
        /// The same in every look (the welcome switches looks itself).
        static let once: [Scene] = [.welcome]

        /// Seconds recorded.
        var length: Double {
            switch self {
            case .open: 9
            case .lyrics: 10
            case .meeting: 8
            case .timer: 9.5
            case .volume: 5
            case .asleep: 9
            case .welcome: 11.5
            case .player: 14.5
            case .awake: 10
            case .menu: 10
            case .app: 8
            }
        }

        /// The stage in points: the top of a desktop, or a whole small screen for the player (your click on the cover
        /// fills it). Both are read at 2x; the player's is written at 1x, so its zoom on the island stays sharp.
        var stage: CGSize { self == .player ? CGSize(width: 1280, height: 720) : CGSize(width: 560, height: 316) }
        /// How many times bigger than real the stage is drawn before it's read (2026-11-16, your report: the hero's
        /// recording was blurry). The site shows the top-of-desktop scenes ~1100 pt wide, twice their real size, so
        /// at 1x the island's 560 pt became 1120 pixels stretched over ~2200 on a Retina screen, and over ~3000 while
        /// the camera zoomed. Drawn twice as big, they're 2240 pixels: sharp at full width. The player stays 1x (it
        /// shows in a small card).
        var detail: CGFloat { self == .player ? 1 : 2 }
        var output: CGSize {
            self == .player ? stage : CGSize(width: stage.width * 2 * detail, height: stage.height * 2 * detail)
        }
    }

    // MARK: One scene

    private static func record(_ scene: Scene, look: IslandAppearance, songs book: SongBook, into folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "com.theojones.Brim.site-capture"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defaults.removePersistentDomain(forName: suite)
        let settings = IslandSettings(defaults: defaults)
        settings.appearance = look
        settings.tipsEnabled = false
        let island = IslandCoordinator()
        let songs = ScriptedSongs(book)
        let nowPlaying = NowPlayingStore(service: songs, island: island)
        let lyrics = LyricsStore(service: MadeUpLyrics(), nowPlaying: nowPlaying)
        let modes = PlayerModesStore(service: StillControls(), nowPlaying: nowPlaying)
        let volume = ScriptedVolume()
        let hud = HUDStore(volume: volume, island: island)
        let timer = TimerStore(island: island, alarm: QuietAlarm(), defaults: defaults)
        let calendar = CalendarStore(service: EmptyCalendar(), island: island)
        let queue = QueueStore(service: UpNext(book.queue), nowPlaying: nowPlaying)
        // Before 2026-11-14 the island here had no keep-awake, so the coffee was missing from every recording's tab row.
        let keepAwake = KeepAwakeStore(service: NoAssertion(), island: island)
        let menu = MenuStage()
        let desk = DeskStage()
        let cursor = CursorModel()
        let camera = Camera()
        let player = PlayerStage()
        keep = [settings, island, songs, nowPlaying, lyrics, modes, volume, hud, timer, calendar, queue, keepAwake, menu, desk,
                cursor, camera, player]
        island.setKeepPillVisible(true)
        island.setIdleStyle(.asleep)
        // The coffee in every recording (your ask, 2026-11-14): keep-awake on, so it shows beside the pill and lit in the
        // tab row. Not in `asleep` (with keep-awake on, the real Brim shows the coffee instead of resting) or `awake`
        // (which turns it on itself).
        if scene != .asleep && scene != .awake { keepAwake.start(minutes: nil) }
        nowPlaying.start()
        lyrics.start()
        hud.start()
        timer.start()

        let stage = scene.stage
        let root = IslandRootView(coordinator: island, nowPlaying: nowPlaying, hud: hud, lyrics: lyrics, modes: modes,
                                  settings: settings, actions: IslandActions(openSettings: {}, quit: {}),
                                  calendar: calendar, timer: timer, keepAwake: keepAwake)
        var steps: [(Double, () -> Void)] = []
        var content = AnyView(root.frame(width: IslandMetrics.panelSize.width, height: IslandMetrics.panelSize.height,
                                         alignment: .top))
        let playing = { (index: Int, elapsed: Double) in songs.play(index, elapsed: elapsed) }
        // Where things are on the stage (560 pt wide, the island centred at 280): the floating looks sit 6 pt lower.
        let dy: CGFloat = look == .black ? 0 : 6
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y + dy) }
        // The camera always keeps the top edge in the picture (y 0): that's where Brim hangs from.
        let islandMiddle = CGPoint(x: 280, y: 0)
        let glance = CGPoint(x: 280, y: 0)
        let away = CGPoint(x: 452, y: 256)

        switch scene {
        case .open:
            playing(0, 42)
            cursor.place(away)
            steps = [(0.8, { cursor.glide(to: at(292, 14), over: 0.9) }),
                     (1.7, { island.hoverChanged(true); camera.zoom(1.32, at: islandMiddle, over: 0.9) }),
                     (2.9, { cursor.glide(to: at(339, 159), over: 0.6) }),         // the next button
                     (3.7, { cursor.click(); playing(1, 0) }),
                     (5.1, { cursor.click(); playing(2, 0) }),
                     (6.3, { cursor.glide(to: away, over: 0.9) }),
                     (6.9, { island.hoverChanged(false); camera.zoom(1, at: islandMiddle, over: 0.9) })]
        case .lyrics:
            songs.playLyricSong(elapsed: 20)
            settings.lyricsEnabled = true
            settings.lyricsModeOn = false
            cursor.place(away)
            steps = [(0.3, { island.hoverChanged(true) }),
                     (0.6, { camera.zoom(1.32, at: islandMiddle, over: 0.9) }),
                     (1.3, { cursor.glide(to: at(405, 78), over: 0.8) }),          // the quote button
                     (2.2, { cursor.click(); settings.lyricsModeOn = true }),
                     (3.0, { cursor.glide(to: CGPoint(x: 486, y: 210), over: 1.0) }),
                     (8.6, { camera.zoom(1, at: islandMiddle, over: 0.9) })]
        case .meeting:
            playing(2, 30)
            await calendar.setEnabled(true)
            calendar.start()
            cursor.place(away)
            steps = [(0.2, { calendar.preview() }),                               // its reminder shows 3 s later
                     (3.5, { camera.zoom(1.36, at: glance, over: 0.8) }),
                     (4.0, { cursor.glide(to: at(414, 16), over: 0.8) }),          // Join
                     (5.0, { cursor.click() }),
                     (5.3, { island.dismiss(.calendar) }),
                     (5.7, { cursor.glide(to: away, over: 0.9); camera.zoom(1, at: glance, over: 0.9) })]
        case .timer:
            playing(0, 90)
            cursor.place(away)
            steps = [(0.8, { timer.start(length: 4) }),                           // the ring; Time's up at 4.8 s
                     (5.1, { camera.zoom(1.36, at: glance, over: 0.8) }),
                     (5.6, { cursor.glide(to: at(412, 16), over: 0.8) }),          // Stop
                     (6.6, { cursor.click() }),
                     (6.9, { timer.stopAlarm(); island.dismiss(.timerDone); timer.cancelAll() }),
                     (7.3, { cursor.glide(to: away, over: 0.9); camera.zoom(1, at: glance, over: 0.9) })]
        case .volume:
            playing(3, 20)
            cursor.hide()
            let levels = [0.42, 0.48, 0.54, 0.6, 0.66, 0.72]
            steps = levels.enumerated().map { index, level in (1.2 + Double(index) * 0.28, { volume.change(to: level) }) }
            steps += [(0.9, { camera.zoom(1.3, at: glance, over: 0.7) }),
                      (3.5, { camera.zoom(1, at: glance, over: 0.8) })]
        case .asleep:
            cursor.place(away)
            steps = [(1.1, { cursor.glide(to: at(280, 18), over: 0.9) }),          // Brim, asleep
                     (2.1, { island.open(page: .timers); camera.zoom(1.32, at: islandMiddle, over: 0.9) }),
                     (3.4, { cursor.glide(to: at(139, 139), over: 0.7) }),         // Start
                     (4.3, { cursor.click(); timer.start(minutes: 25) }),
                     (5.4, { cursor.glide(to: away, over: 0.9) }),
                     (6.0, { island.hoverChanged(false); camera.zoom(1, at: islandMiddle, over: 0.9) })]
        case .awake:
            // Click the coffee in the tab row: its lengths; 1 hour; the coffee beside the pill, its ring draining.
            playing(1, 60)
            cursor.place(away)
            let coffee = at(337, 19)
            let menuAt = at(296, 32)                                               // fits inside the zoomed picture
            steps = [(0.3, { island.hoverChanged(true) }),
                     (0.6, { camera.zoom(1.24, at: islandMiddle, over: 0.9) }),
                     (1.2, { cursor.glide(to: coffee, over: 0.8) }),
                     (2.2, { cursor.click(); menu.show(menus.awake, at: menuAt) }),
                     (3.0, { cursor.glide(to: menu.rowCentre(titled: "1 hour") ?? menuAt, over: 0.7) }),
                     (4.0, { cursor.click(); menu.hide(); keepAwake.start(minutes: 60) }),
                     (5.0, { cursor.glide(to: away, over: 0.9) }),
                     (5.6, { island.hoverChanged(false); camera.zoom(1.2, at: islandMiddle, over: 0.9) }),
                     (8.8, { camera.zoom(1, at: islandMiddle, over: 0.8) })]
        case .menu:
            // A two-finger click on the pill: Brim's menu; Start Timer ▸ 25 min; the timer's ring beside the pill.
            playing(2, 45)
            cursor.place(away)
            let pill = at(280, 14)
            let menuAt = at(283, 20)
            steps = [(0.6, { cursor.glide(to: pill, over: 0.9) }),
                     (1.6, { camera.zoom(1.2, at: glance, over: 0.8) }),
                     (1.9, { cursor.twoFingerClick(); menu.show(menus.pill, at: menuAt) }),
                     (2.7, { cursor.glide(to: menu.rowCentre(titled: "Start Timer") ?? menuAt, over: 0.6) }),
                     (3.4, { menu.openSubmenu(titled: "Start Timer") }),
                     (3.9, { cursor.glide(to: menu.submenuRowCentre(titled: "25 min") ?? menuAt, over: 0.7) }),
                     (4.9, { cursor.click(); menu.hide(); timer.start(minutes: 25) }),
                     (5.7, { cursor.glide(to: away, over: 0.9) }),
                     (8.8, { camera.zoom(1, at: glance, over: 0.8) })]
        case .app:
            // Click the app's icon: its window comes forward from behind another one.
            playing(0, 70)
            cursor.place(away)
            content = AnyView(ZStack(alignment: .top) {
                DeskWindows(desk: desk, song: book.main[0])
                root.frame(width: IslandMetrics.panelSize.width, height: IslandMetrics.panelSize.height, alignment: .top)
            }
            .frame(width: stage.width, height: stage.height, alignment: .top))
            steps = [(0.3, { island.hoverChanged(true) }),
                     (0.6, { camera.zoom(1.32, at: islandMiddle, over: 0.9) }),
                     (1.3, { cursor.glide(to: at(441, 78), over: 0.8) }),          // the app's icon
                     (2.3, { cursor.click(); desk.playerInFront = true }),
                     (2.9, { cursor.glide(to: away, over: 0.9); camera.zoom(1, at: islandMiddle, over: 0.9) }),
                     (3.5, { island.hoverChanged(false) })]
        case .welcome:
            let flow = WelcomeFlow(actions: quietWelcome(), defaults: defaults, resultPause: .milliseconds(900))
            keep += [flow]
            cursor.place(CGPoint(x: 340, y: 158))
            // Brim's eyes follow the drawn pointer (measured from the eyes, at the top middle of the stage).
            content = AnyView(WelcomeView(flow: flow, settings: settings, nowPlaying: nil,
                                          pointer: { CGPoint(x: cursor.position.x - 280, y: cursor.position.y - 18) })
                .frame(width: WelcomeView.width + 12, height: WelcomeView.windowHeight, alignment: .top))
            let card = CGPoint(x: 280, y: 0)
            steps = [(0.1, { flow.startIfNeeded() }),
                     (1.4, { camera.zoom(1.22, at: card, over: 0.9) }),
                     (2.0, { cursor.glide(to: CGPoint(x: 430, y: 150), over: 0.8) }),
                     (3.1, { cursor.glide(to: CGPoint(x: 160, y: 90), over: 0.8) }),
                     (4.2, { cursor.glide(to: CGPoint(x: 280, y: 3), over: 0.6) }),
                     (4.8, { Task { await flow.pointedAtTop() } }),
                     (6.3, { cursor.glide(to: CGPoint(x: 410, y: 171), over: 0.7) }),   // Black Pill
                     (7.1, { cursor.click(); settings.appearance = .blackPill }),
                     (8.0, { cursor.glide(to: CGPoint(x: 150, y: 177), over: 0.7) }),   // Notch
                     (8.8, { cursor.click(); settings.appearance = .black }),
                     (9.5, { cursor.glide(to: CGPoint(x: 443, y: 211), over: 0.6) }),   // Next
                     (10.2, { cursor.click(); flow.next() }),
                     (10.6, { camera.zoom(1, at: card, over: 0.8) })]
        case .player:
            // Your click on the cover: the island opens, the cover is clicked, and the song fills the screen (the real
            // window fades in over 0.3 s; so does this one). Then Lyrics → Queue with the switch in the corner.
            songs.playLyricSong(elapsed: 14)
            settings.lyricsEnabled = true
            settings.fullScreenLyrics = true
            settings.fullScreenQueue = false
            let top = CGPoint(x: 640, y: 0)
            camera.zoom(2.2, at: top, over: 0)                                     // close on the island to begin
            cursor.place(CGPoint(x: 770, y: 220))
            cursor.size = 0.85                                                     // the camera is close: a small arrow
            content = AnyView(ZStack(alignment: .top) {
                root.frame(width: IslandMetrics.panelSize.width, height: IslandMetrics.panelSize.height, alignment: .top)
                PlayerLayer(stage: player) {
                    FullScreenPlayerView(nowPlaying: nowPlaying, lyrics: lyrics, hud: hud, modes: modes, settings: settings,
                                         actions: FullScreenActions(close: {}), queue: queue)
                }
            }
            .frame(width: stage.width, height: stage.height, alignment: .top))
            steps = [(0.8, { cursor.glide(to: CGPoint(x: 652, y: 14 + dy), over: 0.9) }),
                     (1.7, { island.hoverChanged(true) }),
                     (2.7, { cursor.glide(to: CGPoint(x: 493, y: 78 + dy), over: 0.7) }),      // the cover
                     (3.5, { cursor.click() }),
                     (3.7, { player.open = true; island.setFullScreenPlayerOpen(true); camera.zoom(1, at: top, over: 1.1); cursor.size = 1.8 }),
                     (5.0, { cursor.glide(to: CGPoint(x: 1010, y: 450), over: 1.2) }),
                     (8.2, { cursor.glide(to: CGPoint(x: 1249, y: 689), over: 1.0) }),         // the Queue switch
                     (9.3, { cursor.click(); settings.fullScreenQueue = true }),
                     (9.7, { camera.zoom(1.16, at: CGPoint(x: 1010, y: 330), over: 1.0) }),
                     (10.9, { cursor.glide(to: CGPoint(x: 900, y: 300), over: 0.9) }),
                     (13.2, { camera.zoom(1, at: CGPoint(x: 1010, y: 330), over: 0.9) })]
        }

        let screen = NSScreen.main?.visibleFrame ?? .zero
        let detail = scene.detail
        let window = NSWindow(contentRect: NSRect(x: screen.minX + 16, y: screen.minY + 16, width: stage.width * detail,
                                                  height: stage.height * detail),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.ignoresMouseEvents = true
        // No `.clipped()` here: clipping the root made SwiftUI drop the island's AppKit-drawn parts (the progress
        // bar, timeline texts, some button labels) from this window (found 2026-11-11). The window clips anyway.
        window.contentView = NSHostingView(rootView: ZStack(alignment: .top) {
            Wallpaper()
            content
            DrawnMenuLayer(menu: menu, pointer: { cursor.position })
            CursorView(model: cursor)
        }
        .frame(width: stage.width, height: stage.height, alignment: .top)
        // Drawn `detail` times bigger, so the recording has more pixels (SwiftUI draws text and shapes at the scaled
        // size, not as a stretched picture).
        .scaleEffect(detail, anchor: .topLeading)
        .frame(width: stage.width * detail, height: stage.height * detail, alignment: .topLeading)
        .environment(\.colorScheme, .dark))
        window.orderFrontRegardless()
        self.window = window

        for (time, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + time) { action() }
        }
        try? await Task.sleep(for: .milliseconds(600))  // the window's first frames
        let recorder = FrameRecorder(url: folder.appendingPathComponent("\(scene.rawValue).mp4"),
                                     width: Int(scene.output.width), height: Int(scene.output.height))
        let frames = await recorder?.record(window: window, retina: true, camera: camera, stage: stage,
                                            for: scene.length) ?? 0
        Log.app.notice("Site capture: \(folder.lastPathComponent, privacy: .public)/\(scene.rawValue, privacy: .public) · \(frames, privacy: .public) frames")

        timer.cancelAll()
        window.orderOut(nil)
        self.window = nil
        keep = []
        defaults.removePersistentDomain(forName: suite)
        try? await Task.sleep(for: .milliseconds(400))
    }

    /// The welcome's switches, asking macOS for nothing.
    private static func quietWelcome() -> WelcomeFlow.Actions {
        WelcomeFlow.Actions(turnOnCalendar: {}, turnOffCalendar: {}, calendarIsOn: { false },
                            turnOnAirPods: {}, turnOffAirPods: {}, airPodsAreOn: { false },
                            turnOnVolume: {}, turnOffVolume: {}, volumeIsOn: { false },
                            volumeNeedsRestart: { false }, restart: {}, launchAtLoginIsOn: { true },
                            setLaunchAtLogin: { _ in })
    }
}

// MARK: - The drawn pointer and the camera

/// A pointer that exists only in the picture: it glides where the script sends it and marks each click with a ring.
@MainActor @Observable
private final class CursorModel {
    private(set) var position = CGPoint(x: 452, y: 256)
    private(set) var clicks = 0
    private(set) var pressed = false
    private(set) var visible = true
    /// How big the arrow is drawn: the player's stage is a whole screen, so it's drawn larger there.
    var size: CGFloat = 1
    @ObservationIgnored private var gliding: Task<Void, Never>?

    func place(_ point: CGPoint) { position = point }
    func hide() { visible = false }

    func glide(to target: CGPoint, over seconds: Double) {
        gliding?.cancel()
        let from = position
        gliding = Task { @MainActor [weak self] in
            let began = Date()
            while !Task.isCancelled {
                let t = min(1, Date().timeIntervalSince(began) / seconds)
                let eased = t * t * t * (t * (6 * t - 15) + 10)  // smootherstep: it leaves and arrives gently
                // A slight arc, like a hand: the path bows a little off the straight line.
                let bow = sin(.pi * eased) * min(18, abs(target.x - from.x) * 0.08)
                self?.position = CGPoint(x: from.x + (target.x - from.x) * eased,
                                         y: from.y + (target.y - from.y) * eased - bow)
                if t >= 1 { return }
                try? await Task.sleep(for: .milliseconds(12))
            }
        }
    }

    /// Two fingers: the ring is drawn doubled, so a secondary click reads differently from a click.
    private(set) var twoFingers = false

    func twoFingerClick() {
        twoFingers = true
        tap()
    }

    func click() {
        twoFingers = false
        tap()
    }

    private func tap() {
        pressed = true
        clicks += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            self?.pressed = false
        }
    }
}

private struct CursorView: View {
    let model: CursorModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if model.visible {
                ClickRing(double: model.twoFingers).id(model.clicks).opacity(model.clicks == 0 ? 0 : 1)
                    .offset(x: model.position.x - 22, y: model.position.y - 22)
                Image(nsImage: NSCursor.arrow.image)
                    .scaleEffect((model.pressed ? 0.86 : 1) * model.size, anchor: .topLeading)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                    .offset(x: model.position.x - 4, y: model.position.y - 3)  // the arrow's tip sits on the point
                    .animation(.spring(response: 0.18, dampingFraction: 0.7), value: model.pressed)
                    .animation(.easeInOut(duration: 1.0), value: model.size)
            }
        }
        .allowsHitTesting(false)
    }
}

/// One click's ring: it grows from the pointer's tip and fades.
private struct ClickRing: View {
    var double = false
    @State private var grown = false

    var body: some View {
        Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2)
            .background(Circle().fill(.white.opacity(0.14)))
            .overlay { if double { Circle().strokeBorder(.white.opacity(0.75), lineWidth: 1.5).padding(7) } }
            .frame(width: 44, height: 44)
            .scaleEffect(grown ? 1 : 0.2)
            .opacity(grown ? 0 : 1)
            .onAppear { withAnimation(.easeOut(duration: 0.5)) { grown = true } }
    }
}

/// Where the recording looks: how far it's zoomed in, and on what. The script moves it; each picture is cropped to it.
@MainActor
private final class Camera {
    private var from = (scale: 1.0, focus: CGPoint(x: 280, y: 96))
    private var to = (scale: 1.0, focus: CGPoint(x: 280, y: 96))
    private var began = Date.distantPast
    private var seconds = 0.001

    func zoom(_ scale: Double, at focus: CGPoint, over seconds: Double) {
        from = now
        to = (scale, focus)
        began = Date()
        self.seconds = max(0.001, seconds)
    }

    /// The camera at this instant, eased between where it was and where it's going.
    var now: (scale: Double, focus: CGPoint) {
        let t = min(1, Date().timeIntervalSince(began) / seconds)
        let e = t * t * t * (t * (6 * t - 15) + 10)
        return (from.scale + (to.scale - from.scale) * e,
                CGPoint(x: from.focus.x + (to.focus.x - from.focus.x) * e, y: from.focus.y + (to.focus.y - from.focus.y) * e))
    }
}

/// The full-screen player over the stage: off until the script "clicks" the cover.
@MainActor @Observable
private final class PlayerStage {
    var open = false
}

private struct PlayerLayer<Player: View>: View {
    let stage: PlayerStage
    @ViewBuilder let player: () -> Player

    var body: some View {
        ZStack {
            if stage.open {
                player().background(.black).transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.3), value: stage.open)  // the real window's fade
    }
}

// MARK: - Songs

struct Song {
    var title: String
    var artist: String
    var album: String
    var length: Double
    var cover: Data?
}

/// What the scenes play: four songs, the one made-up song used wherever lyrics show, and what's up next.
struct SongBook {
    var main: [Song]
    var lyricSong: Song
    var queue: [Song]

    private static let invented: [(String, String, String, Double)] = [
        ("Paper Lanterns", "Low Tide", "Harbour Lights", 214), ("Midnight Drive", "The Night Shift", "After Hours Radio", 198),
        ("Slow Morning", "June & Co", "Windows Open", 187), ("Golden Field", "Dunes", "Long Way Round", 226)]
    private static let inventedNext: [(String, String)] = [
        ("Low Tide", "Harbor Lights"), ("Violet Hour", "Nova Coast"), ("Paper Planes at Noon", "The Quiet Hours"),
        ("Dunes", "Golden Field"), ("Blue Hour", "Nova Coast"), ("Station Clock", "June & Co"),
        ("Small Hours", "The Night Shift"), ("Open Windows", "Low Tide"), ("Long Way Round", "Dunes")]

    /// Songs that don't exist, with covers drawn here.
    @MainActor static var madeUp: SongBook {
        let main = invented.enumerated().map { index, song in
            Song(title: song.0, artist: song.1, album: song.2, length: song.3, cover: ScriptedSongs.drawnCover(index))
        }
        let next = inventedNext.enumerated().map { index, song in
            Song(title: song.0, artist: song.1, album: "", length: 200, cover: ScriptedSongs.drawnCover(index + 4))
        }
        return SongBook(main: main, lyricSong: main[1], queue: next)
    }

    /// The last four different songs in Brim's History (your pick, 2026-11-11), each with its cover from Apple's public
    /// catalog (itunes.apple.com, the host Brim already uses for album queues), and the ones before them as Up Next
    /// (with History's own small covers). Fewer than four found: made-up ones fill in.
    @MainActor static func fromHistory(_ history: HistoryStore) async -> SongBook {
        // Songs only: what Spotify and Apple Music played (not a browser tab or a video), with an artist, and found
        // in Apple's catalog under the same title. Newest first, until four are found (at most 16 looked up).
        var seen = Set<String>()
        let recent = history.byApp.filter { $0.key == "com.spotify.client" || $0.key == "com.apple.Music" }
            .values.flatMap { $0 }.sorted { $0.playedAt > $1.playedAt }
            .filter { !($0.artist ?? "").isEmpty && seen.insert($0.title.lowercased()).inserted }
        // The first four found are the songs the scenes play; the next nine are Up Next. Every one is looked up, so
        // every cover is the real one (History also holds placeholder pictures). Songs Apple marks explicit are left
        // out (`catalogSong`): this goes on a public page.
        var found: [Song] = []
        for entry in recent.prefix(40) where found.count < 13 {
            if let song = await catalogSong(title: entry.title, artist: entry.artist ?? "") { found.append(song) }
        }
        let made = madeUp
        let songs = Array(found.prefix(4)), next = Array(found.dropFirst(4))
        Log.app.notice("Site capture: \(songs.count, privacy: .public) real songs, \(next.count, privacy: .public) up next from History")
        return SongBook(main: songs + made.main.dropFirst(songs.count), lyricSong: made.lyricSong,
                        queue: next.count >= 5 ? next : made.queue)
    }

    /// The song as Apple's catalog has it (same title), with its cover; nil when it isn't there.
    private static func catalogSong(title: String, artist: String) async -> Song? {
        guard let url = AppleCatalog.searchURL(title: title, artist: artist, country: "us"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        let wanted = title.lowercased()
        guard let match = results.first(where: { result in
            let name = (result["trackName"] as? String ?? "").lowercased()
            return name == wanted || name.hasPrefix(wanted) || wanted.hasPrefix(name) && !name.isEmpty
        }), match["trackExplicitness"] as? String != "explicit",
              let small = match["artworkUrl100"] as? String,
              let big = URL(string: small.replacingOccurrences(of: "100x100bb", with: "600x600bb")),
              big.host?.hasSuffix("mzstatic.com") == true,
              let (art, _) = try? await URLSession.shared.data(from: big), NSImage(data: art) != nil else { return nil }
        return Song(title: title, artist: artist, album: match["collectionName"] as? String ?? "",
                    length: (match["trackTimeMillis"] as? Double).map { $0 / 1000 } ?? 210, cover: art)
    }
}

/// Up Next for the full-screen player's Queue: the list is handed over as it is; nothing is asked of any player.
private final class UpNext: QueueService, @unchecked Sendable {
    private let songs: [Song]
    init(_ songs: [Song]) { self.songs = songs }

    func queue(of player: ScriptablePlayer) async -> PlayerQueue {
        .items(source: nil, songs.enumerated().map { QueueItem(id: "next-\($0.offset)", title: $0.element.title, artist: $0.element.artist) })
    }
    func play(_ item: QueueItem, position: Int, in player: ScriptablePlayer) async -> Bool { true }
    func cover(of item: QueueItem, in player: ScriptablePlayer) async -> Data? {
        Int(item.id.dropFirst(5)).flatMap { songs.indices.contains($0) ? songs[$0].cover : nil }
    }
}

// MARK: - Made-up things

/// A desktop that belongs to nobody: a dim, warm dusk in a soft mesh. Dark enough that Brim is the bright thing in
/// the picture, light enough that the black island and the glass both read.
private struct Wallpaper: View {
    var body: some View {
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.55], [0.55, 0.45], [1, 0.5],
            [0, 1], [0.5, 1], [1, 1],
        ], colors: [
            Color(red: 0.11, green: 0.13, blue: 0.19), Color(red: 0.17, green: 0.17, blue: 0.23), Color(red: 0.3, green: 0.22, blue: 0.22),
            Color(red: 0.2, green: 0.18, blue: 0.23), Color(red: 0.44, green: 0.3, blue: 0.25), Color(red: 0.6, green: 0.42, blue: 0.3),
            Color(red: 0.27, green: 0.18, blue: 0.17), Color(red: 0.52, green: 0.33, blue: 0.23), Color(red: 0.74, green: 0.55, blue: 0.38),
        ])
    }
}

/// The songs the scenes play, in order.
private final class ScriptedSongs: NowPlayingService {
    let events: AsyncStream<NowPlayingEvent>
    private let continuation: AsyncStream<NowPlayingEvent>.Continuation
    private let book: SongBook

    init(_ book: SongBook) {
        self.book = book
        (events, continuation) = AsyncStream.makeStream(of: NowPlayingEvent.self)
    }

    func play(_ index: Int, elapsed: Double) { send(book.main[index % book.main.count], elapsed: elapsed) }
    /// The made-up song for the scenes that show lyrics: its title and its (made-up) words belong together.
    func playLyricSong(elapsed: Double) { send(book.lyricSong, elapsed: elapsed) }

    private func send(_ song: Song, elapsed: Double) {
        var item = NowPlaying(title: song.title, artist: song.artist, album: song.album,
                              bundleIdentifier: "com.apple.Music", isPlaying: true, duration: song.length,
                              elapsed: elapsed, timestamp: .now, playbackRate: 1)
        item.artwork = song.cover
        continuation.yield(.item(item))
    }

    func start() { continuation.yield(.availability(.ready)) }
    func stop() { continuation.finish() }
    func perform(_ command: MediaCommand) async {}
    func seek(to position: TimeInterval) async {}
    func setShuffle(_ on: Bool) async {}
    func setRepeat(_ mode: RepeatMode) async {}

    /// Covers that are nobody's: a sun over water, rings, a moon, a field.
    static func drawnCover(_ index: Int) -> Data? {
        let image = NSImage(size: NSSize(width: 600, height: 600), flipped: false) { rect in
            func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) { NSColor(srgbRed: r, green: g, blue: b, alpha: 1).setFill() }
            switch index {
            case 4...:  // up next: two colours and one shape each, from a small palette
                let palette: [(CGFloat, CGFloat, CGFloat)] = [(0.13, 0.2, 0.33), (0.86, 0.42, 0.3), (0.95, 0.83, 0.6), (0.2, 0.42, 0.4),
                                                              (0.55, 0.3, 0.5), (0.93, 0.62, 0.32), (0.3, 0.33, 0.55), (0.82, 0.78, 0.7)]
                let back = palette[index % palette.count], front = palette[(index * 3 + 2) % palette.count]
                fill(back.0, back.1, back.2)
                rect.fill()
                fill(front.0, front.1, front.2)
                switch index % 3 {
                case 0: NSBezierPath(ovalIn: rect.insetBy(dx: 150, dy: 150)).fill()
                case 1: NSBezierPath(rect: NSRect(x: 0, y: 0, width: 600, height: 240)).fill()
                default:
                    let path = NSBezierPath()
                    path.move(to: NSPoint(x: 0, y: 0)); path.line(to: NSPoint(x: 600, y: 0)); path.line(to: NSPoint(x: 600, y: 600))
                    path.close(); path.fill()
                }
            case 0:  // lanterns: warm discs on deep teal
                NSGradient(colors: [NSColor(srgbRed: 0.05, green: 0.2, blue: 0.24, alpha: 1), NSColor(srgbRed: 0.1, green: 0.34, blue: 0.36, alpha: 1)])?.draw(in: rect, angle: 90)
                for (x, y, size) in [(150.0, 380.0, 150.0), (330.0, 250.0, 110.0), (430.0, 430.0, 70.0)] {
                    fill(0.98, 0.72, 0.36)
                    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: size, height: size)).fill()
                }
            case 1:  // midnight: a moon and a road line
                NSGradient(colors: [NSColor(srgbRed: 0.06, green: 0.06, blue: 0.16, alpha: 1), NSColor(srgbRed: 0.2, green: 0.14, blue: 0.34, alpha: 1)])?.draw(in: rect, angle: 90)
                fill(0.96, 0.93, 0.84)
                NSBezierPath(ovalIn: NSRect(x: 360, y: 360, width: 130, height: 130)).fill()
                fill(0.92, 0.36, 0.42)
                NSBezierPath(rect: NSRect(x: 0, y: 150, width: 600, height: 14)).fill()
            case 2:  // morning: a sun rising over a band
                fill(0.96, 0.9, 0.8)
                rect.fill()
                fill(0.94, 0.5, 0.3)
                NSBezierPath(ovalIn: NSRect(x: 170, y: 150, width: 260, height: 260)).fill()
                fill(0.2, 0.3, 0.42)
                NSBezierPath(rect: NSRect(x: 0, y: 0, width: 600, height: 230)).fill()
            default:  // field: stripes
                fill(0.93, 0.75, 0.38)
                rect.fill()
                for row in 0..<6 {
                    fill(0.55 + CGFloat(row) * 0.05, 0.36 + CGFloat(row) * 0.04, 0.16)
                    NSBezierPath(rect: NSRect(x: 0, y: CGFloat(row) * 52, width: 600, height: 30)).fill()
                }
                fill(0.98, 0.95, 0.88)
                NSBezierPath(ovalIn: NSRect(x: 400, y: 420, width: 90, height: 90)).fill()
            }
            return true
        }
        return image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
    }
}

/// Lines written for this, sung by nobody: one every 2.6 s.
private actor MadeUpLyrics: LyricsService {
    func lyrics(for query: LyricsQuery) async -> LyricsResult {
        let lines = [
            "Somewhere past the station clock",
            "the streetlights hum a quiet tune",
            "walking home through the evening light",
            "counting every window still awake",
            "the river keeps the city's time",
            "and I keep mine a little slow",
            "paper lanterns on the water",
            "carry what I meant to say",
            "hold the sky a little longer",
            "morning knows the way from here",
        ]
        return .found(.synced((0..<80).map { LyricLine(time: 1 + Double($0) * 2.6, text: lines[$0 % lines.count]) }))
    }
    func offset(for query: LyricsQuery) async -> TimeInterval { 0 }
    func setOffset(_ offset: TimeInterval, for query: LyricsQuery) async {}
    func versions(for query: LyricsQuery) async -> LyricsVersionsResult { .failed("capture") }
    func use(_ version: LyricsVersion, for query: LyricsQuery) async {}
}

/// Shuffle and Repeat that answer and do nothing: no player is ever asked.
private actor StillControls: PlayerControlsService {
    func modes(of player: ScriptablePlayer, track: String?) async -> PlayerModes? { PlayerModes(shuffle: false, repeatMode: .off) }
    func setShuffle(_ on: Bool, in player: ScriptablePlayer) async -> Bool { true }
    func setRepeat(_ mode: RepeatMode, in player: ScriptablePlayer) async -> Bool { true }
    func setFavorite(_ on: Bool, in player: ScriptablePlayer, track: String?) async -> Bool { true }
    func perform(_ command: MediaCommand, in player: ScriptablePlayer) async -> Bool { true }
    func seek(to position: TimeInterval, in player: ScriptablePlayer) async -> Bool { true }
    func position(of player: ScriptablePlayer) async -> (seconds: Double, roundTrip: TimeInterval)? { nil }
}

/// A volume that only exists in the picture: your Mac's volume is never read or changed.
private final class ScriptedVolume: VolumeService {
    let events: AsyncStream<VolumeEvent>
    private let continuation: AsyncStream<VolumeEvent>.Continuation
    private var state = VolumeState(level: 0.36, isMuted: false, deviceName: nil, output: nil, isAdjustable: true)

    init() { (events, continuation) = AsyncStream.makeStream(of: VolumeEvent.self) }
    func start() { continuation.yield(.baseline(state)) }
    func currentState() -> VolumeState? { state }
    func change(to level: Double) {
        state.level = level
        continuation.yield(.changed(state))
    }
    @discardableResult func setLevel(_ level: Double) -> Bool { true }
    @discardableResult func setMuted(_ muted: Bool) -> Bool { true }
}

private final class QuietAlarm: TimerAlarm {
    func prepare() {}
    func ring(title: String, body: String) {}
    func silence() {}
}

/// No calendar at all: the meeting comes from `CalendarStore.preview()`.
private final class EmptyCalendar: CalendarService {
    let availability: Availability = .ready
    let changes: AsyncStream<Void>
    init() { changes = AsyncStream { _ in } }
    func requestAccess() async -> Bool { true }
    func eventsToday() -> [CalendarEvent] { [] }
    func calendars() -> [CalendarSource] { [] }
    func start() {}
}

// MARK: - Recording

/// Writes a window's own pixels to an H.264 .mp4, 30 pictures a second. The window is read the way the other
/// benches read it (its own content only: no Screen Recording permission, nothing else on your screen is seen), and
/// each picture goes straight to the encoder, so nothing piles up in memory.
private final class FrameRecorder: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int
    private let height: Int

    init?(url: URL, width: Int, height: Int) {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            // ~4.5 bits a second per 1000 pixels: 3.6 Mbit/s at 1280 × 720, 12.7 at 2240 × 1264.
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(3_600_000, width * height * 9 / 2),
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                              AVVideoMaxKeyFrameIntervalKey: 30],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        self.writer = writer
        self.width = width
        self.height = height
    }

    /// Records for `seconds`; returns how many pictures were written. Each picture is cropped to the camera
    /// (`stage` is the window's size in points), so zooming never touches the views themselves.
    @MainActor
    func record(window: NSWindow, retina: Bool, camera: Camera, stage: CGSize, for seconds: Double) async -> Int {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return 0 }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        let windowID = UInt32(window.windowNumber)
        guard writer.startWriting() else { return 0 }
        writer.startSession(atSourceTime: .zero)
        let began = Date()
        var count = 0
        var next = 0.0
        while true {
            let elapsed = Date().timeIntervalSince(began)
            if elapsed >= seconds { break }
            if elapsed >= next, input.isReadyForMoreMediaData,
               // Only this window (8), its bounds without a frame (1), at 1x (16) unless `retina`.
               let image = create(.null, 8, windowID, retina ? 1 : 1 | 16)?.takeRetainedValue(),
               let buffer = pixelBuffer(from: Self.crop(image, to: camera.now, stage: stage)) {
                adaptor.append(buffer, withPresentationTime: CMTime(seconds: elapsed, preferredTimescale: 600))
                count += 1
                next = elapsed + 1.0 / 30 - 0.004
            }
            try? await Task.sleep(for: .milliseconds(4))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return count
    }

    /// The part of the picture the camera sees: `scale` times closer, keeping `focus` where it is in the frame.
    private static func crop(_ image: CGImage, to camera: (scale: Double, focus: CGPoint), stage: CGSize) -> CGImage {
        guard camera.scale > 1.001 else { return image }
        let px = CGFloat(image.width) / stage.width
        let width = CGFloat(image.width) / camera.scale, height = CGFloat(image.height) / camera.scale
        let x = min(max(0, camera.focus.x * px * (1 - 1 / camera.scale)), CGFloat(image.width) - width)
        let y = min(max(0, camera.focus.y * px * (1 - 1 / camera.scale)), CGFloat(image.height) - height)
        return image.cropping(to: CGRect(x: x, y: y, width: width, height: height)) ?? image
    }

    private func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
// MARK: - Menus and windows drawn for the new scenes (2026-11-14)

/// Keep-awake that asks macOS for nothing: the recording shows the coffee without keeping your Mac awake.
private final class NoAssertion: KeepAwakeService {
    func setAwake(_ on: Bool) -> Bool { true }
}

/// One row of a real Brim menu, read from the NSMenu the app builds.
struct DrawnMenuItem: Identifiable {
    let id = UUID()
    var title: String
    var separator = false
    var enabled = true
    var checked = false
    var submenu: [DrawnMenuItem]?

    @MainActor static func items(of menu: NSMenu) -> [DrawnMenuItem] {
        menu.items.map { item in
            DrawnMenuItem(title: item.title, separator: item.isSeparatorItem, enabled: item.isEnabled,
                          checked: item.state == .on, submenu: item.submenu.map { items(of: $0) })
        }
    }
}

/// Which menu shows, where (its top-left corner on the stage), and which submenu is open.
@MainActor @Observable
private final class MenuStage {
    private(set) var items: [DrawnMenuItem] = []
    private(set) var origin = CGPoint.zero
    private(set) var submenu: (items: [DrawnMenuItem], origin: CGPoint)?

    static let width: CGFloat = 178
    static let row: CGFloat = 22
    static let separator: CGFloat = 11
    static let inset: CGFloat = 5

    func show(_ items: [DrawnMenuItem], at point: CGPoint) {
        self.items = items
        origin = point
        submenu = nil
    }

    func hide() {
        items = []
        submenu = nil
    }

    /// Where a row's centre is, given the menu's top-left corner: rows are 22 pt, separators 11 pt, 5 pt inset.
    static func rowTop(_ index: Int, in items: [DrawnMenuItem]) -> CGFloat {
        inset + items.prefix(index).reduce(0) { $0 + ($1.separator ? separator : row) }
    }

    static func height(of items: [DrawnMenuItem]) -> CGFloat { rowTop(items.count, in: items) + inset }

    func rowCentre(titled title: String) -> CGPoint? {
        guard let index = items.firstIndex(where: { $0.title == title }) else { return nil }
        return CGPoint(x: origin.x + 60, y: origin.y + Self.rowTop(index, in: items) + Self.row / 2)
    }

    /// Opens a row's submenu beside it: to the right, or to the left when the stage's edge is near (as macOS does).
    func openSubmenu(titled title: String, stageWidth: CGFloat = 560) {
        guard let index = items.firstIndex(where: { $0.title == title }), let sub = items[index].submenu else { return }
        let y = origin.y + Self.rowTop(index, in: items) - Self.inset
        let right = origin.x + Self.width - 4
        let x = right + Self.width > stageWidth - 4 ? origin.x - Self.width + 4 : right
        submenu = (sub, CGPoint(x: x, y: y))
    }

    func submenuRowCentre(titled title: String) -> CGPoint? {
        guard let submenu, let index = submenu.items.firstIndex(where: { $0.title == title }) else { return nil }
        return CGPoint(x: submenu.origin.x + 60, y: submenu.origin.y + Self.rowTop(index, in: submenu.items) + Self.row / 2)
    }
}

/// The menus, drawn like macOS's: a frosted panel, 13 pt text, the row under the pointer lit in the accent colour.
private struct DrawnMenuLayer: View {
    let menu: MenuStage
    let pointer: () -> CGPoint

    var body: some View {
        TimelineView(.animation) { _ in
            ZStack(alignment: .topLeading) {
                Color.clear
                if !menu.items.isEmpty {
                    panel(menu.items, at: menu.origin, open: menu.submenu == nil ? nil : openTitle)
                }
                if let submenu = menu.submenu {
                    panel(submenu.items, at: submenu.origin, open: nil)
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: menu.items.count)
    }

    private var openTitle: String? { menu.items.first { $0.submenu != nil && menu.submenu?.items.first?.title == $0.submenu?.first?.title }?.title }

    private func panel(_ items: [DrawnMenuItem], at origin: CGPoint, open: String?) -> some View {
        let point = pointer()
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if item.separator {
                    Rectangle().fill(.white.opacity(0.12)).frame(height: 1).padding(.horizontal, 10).frame(height: MenuStage.separator)
                } else {
                    let top = origin.y + MenuStage.rowTop(index, in: items)
                    let under = point.x >= origin.x && point.x <= origin.x + MenuStage.width && point.y >= top && point.y < top + MenuStage.row
                    let lit = item.enabled && (under || item.title == open)
                    HStack(spacing: 0) {
                        Text(item.checked ? "✓" : "").font(.system(size: 12, weight: .semibold)).frame(width: 18)
                        Text(item.title).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 8)
                        if item.submenu != nil { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)) }
                    }
                    .foregroundStyle(item.enabled ? Color.white.opacity(lit ? 1 : 0.92) : Color.white.opacity(0.38))
                    .padding(.horizontal, 6)
                    .frame(height: MenuStage.row)
                    .background(RoundedRectangle(cornerRadius: 5).fill(lit ? Color.accentColor : .clear))
                    .padding(.horizontal, 5)
                }
            }
        }
        .padding(.vertical, MenuStage.inset)
        .frame(width: MenuStage.width, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.16).opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        .offset(x: origin.x, y: origin.y)
        .transition(.opacity)
    }
}

/// The `app` scene's desktop: a music player's window behind a document; the click brings the player forward.
@MainActor @Observable
private final class DeskStage {
    var playerInFront = false
}

/// Two plain windows that belong to no real app.
private struct DeskWindows: View {
    let desk: DeskStage
    let song: Song

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            window(title: song.album) { player }
                .frame(width: 300, height: 176)
                .offset(x: 76, y: 108)
                .zIndex(desk.playerInFront ? 2 : 0)
                .scaleEffect(desk.playerInFront ? 1 : 0.985)
                .opacity(desk.playerInFront ? 1 : 0.9)
            window(title: "Notes for Thursday") { document }
                .frame(width: 290, height: 168)
                .offset(x: 196, y: 128)
                .zIndex(1)
        }
        .frame(width: 560, height: 316, alignment: .topLeading)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: desk.playerInFront)
    }

    private func window<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) {
                    Circle().fill($0).frame(width: 9, height: 9)
                }
                Spacer()
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Color.clear.frame(width: 39, height: 1)
            }
            .padding(.horizontal, 10).frame(height: 24)
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
    }

    private var player: some View {
        HStack(spacing: 14) {
            Group {
                if let data = song.cover, let image = NSImage(data: data) { Image(nsImage: image).resizable() } else { Color.gray }
            }
            .frame(width: 100, height: 100).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(song.title).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                Text(song.artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                Capsule().fill(.white.opacity(0.2)).frame(height: 4)
                    .overlay(alignment: .leading) { Capsule().fill(.white.opacity(0.8)).frame(width: 52, height: 4) }
                    .padding(.top, 10)
            }
        }
        .padding(.horizontal, 16)
    }

    private var document: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([0.9, 0.75, 0.85, 0.5, 0.7], id: \.self) { width in
                Capsule().fill(.white.opacity(0.14)).frame(width: 250 * width, height: 6)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
#endif

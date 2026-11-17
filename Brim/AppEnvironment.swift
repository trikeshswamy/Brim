import AppKit
import os
import SwiftUI
import BrimCore
import BrimSystem
import BrimFeatures

/// The composition root: live services go in, stores and windows come out.
/// This is the only file that imports both BrimSystem and BrimFeatures (architecture §3).
final class AppEnvironment {
    let island = IslandCoordinator()
    /// Live screen facts shared by the AppKit window and the SwiftUI island layout.
    let islandGeometry = IslandDisplayGeometryStore()
    /// Calendar on at first only if access was already given: no prompt on a first launch (PRD F8).
    let islandSettings = IslandSettings(calendarOnAtFirst: EventKitCalendarService.isAuthorized,
                                        headphonesOnAtFirst: BluetoothHeadphonesService.isAuthorized)
    let nowPlayingService = LiveNowPlayingService()
    /// Spotify's Web API for Shuffle & Repeat from anywhere, once you sign in (your decision, 2026-10-02).
    let spotifyWeb = SpotifyWebAPI()
    /// Spotify and Music by Apple Events: shuffle/repeat, and play/pause etc. while Brim shows them on their own.
    let playerControls: AppleEventPlayerControls
    private lazy var spotifyAccount = SpotifyAccountStore(service: spotifyWeb)
    let fullScreen = FrontFullScreenWatcher()
    private var spotifyLaunch: NSObjectProtocol?
    /// LRCLIB plus the cache and your fixes. Kept here so the health log can read its counters.
    let lyricsService = LiveLyricsService(userAgent: AppEnvironment.userAgent)
    let volumeService = CoreAudioVolumeService()
    let mediaKeys = MediaKeyTap()
    let brightnessService = DisplayBrightnessService()
    let nowPlaying: NowPlayingStore
    let hud: HUDStore
    let keyTakeover: KeyTakeover
    let lyrics: LyricsStore
    let playerModes: PlayerModesStore
    /// The full-screen player's queue (2026-10-29): Spotify's Web API, Music's own playlist, nothing from other apps.
    private lazy var queue = QueueStore(service: playerControls, nowPlaying: nowPlaying)
    /// History above Up Next (2026-10-29): per app, the last 50 songs, in Application Support.
    private(set) lazy var history = HistoryStore(service: playerControls, file: HistoryFileStore(), nowPlaying: nowPlaying)
    let settings = SettingsModel(launcher: LaunchAtLoginService())
    /// The sound outputs for the output picker (C1).
    let audioOutputs = AudioOutputsStore(service: CoreAudioOutputsService())
    /// The Mac's battery notices (P-4).
    lazy var battery = BatteryStore(service: IOKitBatteryService(), island: island)
    /// AirPods and headphones connecting, with their battery (P-4).
    lazy var headphones = HeadphonesStore(service: BluetoothHeadphonesService(), island: island)
    /// Your next event and the 5-minute reminder (P-4, F8).
    lazy var calendar = CalendarStore(service: EventKitCalendarService(), island: island)
    /// The one timer (P-4, F9).
    lazy var timer = TimerStore(island: island, alarm: SystemTimerAlarm())
    /// Focus history (feature 3): sessions on your Mac, your labels.
    lazy var focusHistory = FocusHistoryStore(service: FocusHistoryFile())
    /// Keep-awake (F11): the coffee switch.
    lazy var keepAwake = KeepAwakeStore(service: PowerAssertionKeepAwake(), island: island)
    let systemEvents = SystemEventsObserver()
    /// One line of numbers every 10 minutes in ~/Library/Application Support/Brim/health.jsonl (your pick, 2026-09-30).
    private lazy var healthLog = HealthLog(environment: self)
    /// For "Time's up": only opening the island stops it (see `start`).
    private var islandWasOpen = false
    /// What could ride beside the pill last time: something not in it is new, and brings swiped-away bubbles back.
    private var sideActivities: Set<SideActivity> = []

    /// One-time tips under the open island, and the hand-off after the welcome (2026-11-11).
    private lazy var tips = TipsStore(settings: islandSettings)
    private lazy var handoff = HandoffController(island: island, settings: islandSettings)

    private lazy var islandWindow = IslandWindowController(
        coordinator: island,
        settings: islandSettings,
        rootView: IslandRootView(coordinator: island, nowPlaying: nowPlaying, hud: hud, lyrics: lyrics,
                                 modes: playerModes, settings: islandSettings, actions: islandActions, outputs: audioOutputs,
                                 battery: battery, headphones: headphones, calendar: calendar, timer: timer,
                                 keepAwake: keepAwake, tips: tips, geometry: islandGeometry),
        geometry: islandGeometry
    )
    private lazy var fullScreenPlayer = FullScreenPlayerController(
        coordinator: island, playPause: { [unowned self] in nowPlaying.togglePlayPause() },
        next: { [unowned self] in nowPlaying.nextTrack() }, back: { [unowned self] in nowPlaying.restartOrPrevious() }
    ) { [unowned self] actions in
        FullScreenPlayerView(nowPlaying: nowPlaying, lyrics: lyrics, hud: hud, modes: playerModes,
                             settings: islandSettings, actions: actions, outputs: audioOutputs, queue: queue, history: history,
                             appVolume: appVolume)
    }
    /// ⌥⌘, from any app opens Settings (2026-11-17).
    private lazy var settingsHotKey = SettingsHotKey { [weak self] in self?.openSettings() }
    /// Music's or Spotify's own volume, for the full-screen slider (2026-11-17).
    private lazy var appVolume = AppVolumeStore(service: playerControls, nowPlaying: nowPlaying)
    /// The first-launch welcome, round 3 (your picks, 2026-11-11): each permission only when you flip its switch.
    private(set) lazy var welcomeFlow = WelcomeFlow(actions: WelcomeFlow.Actions(
        turnOnCalendar: { [unowned self] in
            islandSettings.calendarEnabled = true
            await calendar.requestPermission()
        },
        turnOffCalendar: { [unowned self] in islandSettings.calendarEnabled = false },
        calendarIsOn: { [unowned self] in islandSettings.calendarEnabled && EventKitCalendarService.isAuthorized },
        turnOnAirPods: { [unowned self] in
            islandSettings.headphonesNotices = true
            headphones.requestPermission()
        },
        turnOffAirPods: { [unowned self] in islandSettings.headphonesNotices = false },
        // On as soon as you flip it: Bluetooth answers later, and Settings → Permissions says if macOS refused.
        airPodsAreOn: { [unowned self] in islandSettings.headphonesNotices },
        turnOnVolume: { [unowned self] in
            islandSettings.brimHUDOnly = true
            guard !AXIsProcessTrusted() else { return }
            // Asking through macOS puts Brim in the Accessibility list (switched off) and shows its own dialog; the
            // pane opens too, in case macOS has stopped showing that dialog for Brim.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        },
        turnOffVolume: { [unowned self] in islandSettings.brimHUDOnly = false },
        volumeIsOn: { [unowned self] in islandSettings.brimHUDOnly && AXIsProcessTrusted() },
        // Allowed, but Brim's own volume display only starts with Brim: Done restarts.
        volumeNeedsRestart: { [unowned self] in
            AXIsProcessTrusted() && islandSettings.brimHUDOnly && keyTakeover.access != .active
        },
        // After the card has shrunk back into the pill (WelcomeController waits 0.42 s for it).
        restart: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { AppEnvironment.relaunch() } },
        launchAtLoginIsOn: { [unowned self] in
            settings.refresh()
            return settings.launchAtLogin != .off
        },
        setLaunchAtLogin: { [unowned self] on in settings.setLaunchAtLogin(on) }
    ))
    private lazy var welcome = WelcomeController(flow: welcomeFlow, island: island, settings: islandSettings,
                                                 nowPlaying: nowPlaying)
    /// In-app updates (Sparkle, 2026-10-29); created at launch so the daily check runs.
    let updates = Updates()
    private lazy var settingsWindow = SettingsWindowController { [unowned self] in
        SettingsView(settings: settings, island: islandSettings, nowPlaying: nowPlaying, keys: keyTakeover,
                     headphones: headphones, calendar: calendar, spotify: spotifyAccount, focus: focusHistory,
                     copyDiagnostics: { [unowned self] in copyDiagnostics() },
                     showWelcome: { [unowned self] in welcomeFlow.showAgain() },
                     checkForUpdates: { [unowned self] in updates.check() })
    }

    init() {
        playerControls = AppleEventPlayerControls(spotifyWeb: spotifyWeb)
        // Spotify's covers from its Web API while it's shown on its own (0.17.3): only once you've signed in.
        nowPlaying = NowPlayingStore(service: nowPlayingService, island: island,
                                     players: DistributedPlayerAnnouncements(), controls: playerControls,
                                     coverSource: SpotifyCovers(web: spotifyWeb, controls: playerControls))
        hud = HUDStore(volume: volumeService, island: island)
        keyTakeover = KeyTakeover(keys: mediaKeys, volume: volumeService, brightness: brightnessService, hud: hud)
        lyrics = LyricsStore(service: lyricsService, nowPlaying: nowPlaying)
        playerModes = PlayerModesStore(service: playerControls, nowPlaying: nowPlaying)
    }

    /// Spotify's own scripting first (free, nothing over the network); its Web API only if that didn't answer.
    private static func spotifyAtLaunch(scripting: AppleEventPlayerControls, web: SpotifyWebAPI) async -> PlayerAnnouncement? {
        if let state = await scripting.spotifyAnnouncementByScript() { return state }
        return await web.playerAnnouncement()
    }

    /// LRCLIB asks apps to identify themselves. Name and version only: no personal details.
    static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "Brim/\(version) (macOS)"
    }

    /// Copies a deliberately redacted support report. This is for a user or maintainer to paste into an issue:
    /// it contains state and dimensions, never media metadata, URLs, account identifiers or entered text.
    private func copyDiagnostics() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let screens = NSScreen.screens.enumerated().map { index, screen in
            let frame = screen.frame.integral
            return "screen\(index): \(Int(frame.width))x\(Int(frame.height)) @\(screen.backingScaleFactor)x"
        }.joined(separator: "; ")
        let geometry = islandGeometry.value
        let notch = geometry.notchWidth.map { "\(Int($0))pt" } ?? "none"
        let lastUpdate = nowPlaying.lastEventAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never"
        let report = """
        Brim diagnostics
        Version: \(version) (\(build))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Screens: \(screens.isEmpty ? "none" : screens)
        Brim display geometry: \(Int(geometry.screenSize.width))x\(Int(geometry.screenSize.height)), notch \(notch), safe top \(Int(geometry.topSafeInset))pt, scale \(geometry.backingScale)x
        Now Playing status: \(String(describing: nowPlaying.availability))
        Now Playing helper: \(nowPlaying.helper.processID.map(String.init) ?? "not running")
        Helper restarts: \(nowPlaying.helper.restarts)
        Last Now Playing update: \(lastUpdate)
        Accessibility media-key access: \(String(describing: keyTakeover.access))
        Calendar access: \(String(describing: calendar.availability))
        Bluetooth access: \(String(describing: headphones.availability))
        Health log: Application Support/Brim/health.jsonl
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    func start() {
        // Settings → coordinator: "Keep music visible", "Show it as" and "In full-screen apps" apply the moment you
        // change them.
        observe { [weak self] in
            guard let self else { return }
            self.island.setKeepPillVisible(self.islandSettings.keepPillVisible)
            self.island.setIdleStyle(self.islandSettings.idleStyle)
            self.island.setKeptStyle(self.islandSettings.keptStyle)
            self.island.setFullScreenIsland(self.islandSettings.fullScreen)
        }
        // Does Spotify answer its scripting? At start and each time Spotify launches (it settles first): when it does,
        // Shuffle & Repeat work from anywhere again (Spotify 1.3.3 doesn't, 2026-10-02).
        Task { [playerControls] in
            try? await Task.sleep(for: .seconds(5))
            await playerControls.checkSpotifyScripting()
        }
        spotifyLaunch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [playerControls] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == ScriptablePlayer.spotify.rawValue else { return }
            Task {
                try? await Task.sleep(for: .seconds(10))
                await playerControls.checkSpotifyScripting()
            }
        }
        // A macOS Focus with a Brim filter: its island and notices (feature 2). The Focus already on, read once.
        FocusFilterBridge.island = island
        Task { await FocusFilterBridge.syncCurrent() }
        // A full-screen front window: the island hides, or rests as the slim line if you chose that (your reports,
        // 2026-10-02).
        fullScreen.onChange = { [weak self] full in self?.island.setFrontIsFullScreen(full) }
        fullScreen.start()
        // The calendar reminder's Join end opens the meeting; the rest of the pill opens the island as usual.
        islandWindow.onCompactClick = { [weak self] x, width in
            guard let self else { return false }
            // "Time's up": the area beside Stop starts what's next (a Break after Focus, Focus after a Break);
            // anywhere else stops it.
            if self.island.surface == .compact(.timerDone) {
                let nextStart = width - IslandMetrics.timesUpStopZone - IslandMetrics.timesUpBreakZone
                if self.timer.ended != nil, x >= nextStart, x < width - IslandMetrics.timesUpStopZone {
                    self.timer.startNext()
                } else {
                    self.timer.stopAlarm()
                }
                return true
            }
            guard self.island.surface == .compact(.calendar), let url = self.calendar.reminding?.meetingURL,
                  x >= width - IslandMetrics.reminderJoinZone else { return false }
            Usage.note("calendar.join")
            NSWorkspace.shared.open(url)
            return true
        }
        islandWindow.sideBubbles = { [weak self] in
            guard let self else { return SideBubbles.none }
            return self.sideBubbles(hiding: self.island.hiddenBubbles)
        }
        // A countdown bubble opens its tab: Calendar for a class, Timers for a timer.
        islandWindow.slimMarks = { [weak self] in
            guard let self else { return SideBubbles.none }
            return IslandSides.slimMarks(timer: self.timer, calendar: self.calendar, keepAwake: self.keepAwake.isOn)
        }
        islandWindow.onRightBubbleClick = { [weak self] in
            guard let self else { return }
            let right = self.island.surface == .slim
                ? IslandSides.slimMarks(timer: self.timer, calendar: self.calendar, keepAwake: self.keepAwake.isOn).right
                : self.sideBubbles(hiding: self.island.hiddenBubbles).right
            if case .event = right {
                self.island.open(page: .calendar)
            } else {
                self.island.open(page: .timers)
            }
        }
        // ⌥⌘, opens Settings from any app, while Settings → Keyboard has it on; it says so if another app has it.
        observe { [weak self] in
            guard let self else { return }
            let taken = !self.settingsHotKey.setEnabled(self.islandSettings.settingsShortcut)
            if self.islandSettings.settingsShortcutTaken != taken { self.islandSettings.settingsShortcutTaken = taken }
        }
        // ⌃ + the volume keys: only the music app's own volume, shown in Brim's HUD with a note (2026-11-17).
        keyTakeover.musicVolumeKey = { [weak self] up, fine in self?.appVolume.step(up: up, fine: fine) ?? false }
        appVolume.onStep = { [weak self] level, player in
            self?.hud.appVolumeChanged(to: level, app: player == .spotify ? "Spotify" : "Music")
        }
        appVolume.start()
        // Esc in the full-screen player first closes the lyrics timing bar, if it's open.
        fullScreenPlayer.escapeFirst = { [weak self] in
            guard let self, self.lyrics.syncing != nil else { return false }
            self.lyrics.endSync()
            return true
        }
        islandWindow.onLeftCountdownClick = { [weak self] in
            guard let self else { return }
            if case .event = self.sideBubbles(hiding: self.island.hiddenBubbles).leftCountdown {
                self.island.open(page: .calendar)
            } else {
                self.island.open(page: .timers)
            }
        }
        islandWindow.timerRows = { [weak self] in min(self?.timer.items.count ?? 0, 2) }
        islandWindow.agendaRows = { [weak self] in self?.calendar.agenda.count ?? 0 }
        islandWindow.pillMenu = { [weak self] in self?.makePillMenu() }
        islandWindow.onSwipe = { [weak self] side in
            // A swipe on a bubble hides that bubble; on the pill it brings hidden ones back; the pill always stays
            // (docs/05-interaction-model.md, decision 9). A haptic tick confirms it.
            guard let self, self.island.swipe(on: side, available: self.sideBubbles(hiding: [])) else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        // Something new starting (a timer, keep-awake, a class entering its 10 minutes) brings swiped-away bubbles back.
        observe { [weak self] in
            guard let self else { return }
            let now = SideRules.activities(keepAwake: self.keepAwake.isOn, timers: self.timer.items.map(\.id),
                                           soonEvent: self.calendar.soon?.id)
            defer { self.sideActivities = now }
            let comingBack = SideRules.newSides(now, since: self.sideActivities)
            if !comingBack.isEmpty { self.island.showBubbles(comingBack) }
        }
        islandWindow.show()
        _ = welcome  // listens to the flow before it starts
        welcomeFlow.onHandOff = { [weak self] in self?.handoff.showSoon() }
        welcomeFlow.startIfNeeded()
        nowPlaying.start()
        // Spotify already playing as Brim starts (0.18.2): Spotify announces itself only when something changes, so
        // behind a paused tab Brim couldn't know. Its Web API is asked once (signed in only; your phone doesn't count).
        Task { [nowPlaying, spotifyWeb, playerControls] in
            try? await Task.sleep(for: .seconds(2))  // macOS's Now Playing first
            let spotify = ScriptablePlayer.spotify.rawValue
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: spotify).isEmpty,
                  !(nowPlaying.item?.sourceBundleIdentifier == spotify && nowPlaying.item?.isPlaying == true),
                  let state = await Self.spotifyAtLaunch(scripting: playerControls, web: spotifyWeb),
                  state.state == .playing else { return }
            // Spotify's own scripting first (free, nothing over the network); its Web API only if that didn't answer.
            Log.nowPlaying.notice("Spotify was already playing as Brim started: shown")
            nowPlaying.seed(state)
        }
        audioOutputs.start()
        // Settings → Notices → Battery.
        observe { [weak self] in
            guard let self else { return }
            self.battery.enabled = self.islandSettings.batteryNotices
        }
        battery.start()
        observe { [weak self] in
            guard let self else { return }
            self.headphones.enabled = self.islandSettings.headphonesNotices
            // Bluetooth monitoring starts when notices are on, but a first-time permission prompt is only opened
            // by the explicit Grant Access action in Settings.
            if self.islandSettings.headphonesNotices { self.headphones.start() }
        }
        headphones.onConnection = { [weak self] connection, shown in
            // Levels and whether it showed; never the name (it usually has yours in it).
            let battery = connection.battery
            self?.healthLog.event("headphones", ["shown": shown, "atLaunch": connection.wasConnectedAtStart,
                                                 "disconnected": connection.disconnected,
                                                 "named": battery.name != nil, "left": battery.left ?? 0,
                                                 "right": battery.right ?? 0, "case": battery.caseLevel ?? 0,
                                                 "single": battery.single ?? 0])
        }
        // Settings → Calendar. Enabling it never opens a permission prompt; Settings owns the explicit request.
        calendar.onReminder = { [weak self] lateBy in
            self?.healthLog.event("calendar-reminder", ["lateMs": Int((lateBy * 1000).rounded())])
        }
        observe { [weak self] in
            guard let self else { return }
            let on = self.islandSettings.calendarEnabled
            self.calendar.remindersEnabled = self.islandSettings.calendarReminders
            self.calendar.hiddenCalendars = self.islandSettings.hiddenCalendars
            Task { await self.calendar.setEnabled(on) }
        }
        calendar.start()
        timer.onEnd = { [weak self] lateBy in
            self?.healthLog.event("timer-end", ["lateMs": Int((lateBy * 1000).rounded())])
        }
        timer.history = focusHistory
        focusHistory.onEditLabels = { [weak self] in self?.openSettings() }
        focusHistory.start()
        timer.start()
        // Opening the island while "Time's up" sounds counts as seeing it: the sound stops. Only the opening:
        // a timer that ends while the island is already open shows its banner and rings until you click it.
        observe { [weak self] in
            guard let self else { return }
            let open = self.island.surface.isExpanded
            defer { self.islandWasOpen = open }
            if open, !self.islandWasOpen, self.timer.ringing { self.timer.stopAlarm() }
        }
        hud.start()
        // Settings → HUD → "Show only Brim's HUD": Brim takes over the volume and brightness keys.
        observe { [weak self] in
            guard let self else { return }
            self.keyTakeover.setEnabled(self.islandSettings.brimHUDOnly)
        }
        // Settings → Media & Lyrics.
        observe { [weak self] in
            guard let self else { return }
            self.lyrics.setEnabled(self.islandSettings.lyricsEnabled)
        }
        lyrics.start()
        history.start()
        #if DEBUG
        KeySelfTest.startIfRequested(environment: self)
        QueueCheck.startIfRequested(environment: self)
        renderQueueIfRequested()
        ControlsValidation.startIfRequested(environment: self)
        LyricsTrace.startIfRequested(environment: self)
        P3Checks.startIfRequested(environment: self)
        LyricsBench.startIfRequested(environment: self)
        IslandBench.startIfRequested(environment: self)
        SiteCapture.startIfRequested(environment: self)
        // `--settings-check <file>`: opens Settings the first time, as the menu does, and writes where it landed.
        if let flag = CommandLine.arguments.firstIndex(of: "--settings-check"), flag + 1 < CommandLine.arguments.count {
            let file = CommandLine.arguments[flag + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.openSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let frames = self?.settingsWindow.frames
                    let icon = NSApp.applicationIconImage.map { "icon \(Int($0.size.width))x\(Int($0.size.height)), \($0.representations.count) sizes, largest \($0.representations.map(\.pixelsWide).max() ?? 0) px\n" } ?? "no icon\n"
                    var text = (frames.map { "window \($0.window)\nscreen \($0.screen)\n" } ?? "no window\n") + icon
                    // ⌘W, sent the way a key press arrives, must close Settings (your ask, 2026-11-17).
                    let key = NSApp.keyWindow?.title ?? "none"
                    if let press = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil,
                                                    characters: "w", charactersIgnoringModifiers: "w",
                                                    isARepeat: false, keyCode: 13) {
                        NSApp.sendEvent(press)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let open = NSApp.windows.contains { $0.title == "Brim Settings" && $0.isVisible }
                        text += "key window \(key)\ncmd-w \(open ? "left Settings open" : "closed Settings")\n"
                        try? text.write(toFile: file, atomically: true, encoding: .utf8)
                        NSApp.terminate(nil)
                    }
                }
            }
        }
        P4Checks.startIfRequested(environment: self)
        #if DEBUG
        if let flag = CommandLine.arguments.firstIndex(of: "--ax-dump"), flag + 1 < CommandLine.arguments.count {
            // `--ax-dump <file>`: what VoiceOver reads in the open island, every Settings page and the full-screen
            // player (the VoiceOver pass, 2026-11-17). See AXDump.
            let file = CommandLine.arguments[flag + 1]
            runAXDump(into: file)
        }
        #endif
        if CommandLine.arguments.contains("--open-fullscreen") {
            // Debug: open the full-screen player at launch, for measuring it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.fullScreenPlayer.open() }
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--hold-island"), flag + 1 < CommandLine.arguments.count {
            // Debug: open the island on a tab (music, timers, calendar) and keep it open 30 s wherever the pointer is,
            // so the real island can be screenshotted (0.13.2: the ruler's pointer, the artwork's inset).
            let page: ExpandedPage = switch CommandLine.arguments[flag + 1] {
            case "timers": .timers
            case "calendar": .calendar
            default: .music
            }
            let capture = CommandLine.arguments.firstIndex(of: "--capture-island")
                .flatMap { $0 + 1 < CommandLine.arguments.count ? URL(fileURLWithPath: CommandLine.arguments[$0 + 1]) : nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.island.open(page: page)
                self?.islandWindow.debugHold(for: capture == nil ? 30 : 6)
            }
            #if DEBUG
            if let capture, page == .music {
                // `--capture-island <dir>`: pictures of the real island (its own window only, no screen recording)
                // while the pair beside the controls switches and switches back (0.18.0), with the real animation.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
                    guard let self else { return }
                    LyricsBench.captureFrames(of: self.islandWindow.debugPanel, into: capture, from: 0, for: 2.6, retina: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        withAnimation(SideButtonsSwitch.animation(reduceMotion: false)) {
                            self.islandSettings.sideButtons = self.islandSettings.sideButtons.other
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.9) {
                        self.islandSettings.sideButtons = self.islandSettings.sideButtons.other  // yours back
                    }
                }
            }
            #endif
            if page == .timers, CommandLine.arguments.contains("--ruler-probe") {
                // Walks the ruler through several lengths (the probe logs each landing), then puts yours back.
                let original = timer.pickedMinutes
                for (step, minutes) in [7, 42, 113, 180, 1, original].enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5 + Double(step) * 2.5) { [weak self] in
                        self?.timer.pickedMinutes = minutes
                    }
                }
            }
        }
        #endif
        systemEvents.onWake = { [weak self] in
            Log.app.notice("Woke from sleep: refreshing Now Playing")
            self?.nowPlayingService.restart()
        }
        systemEvents.onScreensChanged = { [weak self] in
            self?.islandWindow.reposition()
            self?.welcome.reposition()
        }
        systemEvents.start()
        healthLog.start()
    }

    func stop() {
        healthLog.stop()
        nowPlaying.stop()
    }

    /// Opens a new Brim, then quits this one: Accessibility is applied when Brim starts (the welcome's last step).
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error { Log.app.error("Relaunch failed: \(error.localizedDescription, privacy: .public)") }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func openSettings() {
        Usage.note("settings.open")
        settingsWindow.show()
    }

    /// Right-click on the pill: timer shortcuts first (the fastest way to start one), then the usual items.
    func makePillMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false  // "Full-Screen Player" is off when nothing plays
        if timer.canStartAnother {
            let start = NSMenuItem(title: "Start Timer", action: nil, keyEquivalent: "")
            let presets = NSMenu()
            presets.autoenablesItems = false
            for minutes in TimerState.presets {
                presets.addItem(.closure("\(minutes) min") { [weak self] in self?.timer.start(minutes: minutes) })
            }
            start.submenu = presets
            menu.addItem(start)
        }
        if !timer.items.isEmpty {
            menu.addItem(.closure(timer.items.count == 1 ? "Cancel Timer" : "Cancel All Timers") { [weak self] in
                self?.timer.cancelAll()
            })
        }
        menu.addItem(.separator())
        let awake = NSMenuItem(title: "Keep Mac Awake", action: nil, keyEquivalent: "")
        awake.state = keepAwake.isOn ? .on : .off
        awake.submenu = makeKeepAwakeMenu()
        menu.addItem(awake)
        menu.addItem(.closure("Keep Music Visible", checked: islandSettings.keepPillVisible) { [weak self] in
            guard let self else { return }
            self.islandSettings.keepPillVisible.toggle()
        })
        // The swipe's click path (PRD §8.3): the side bubbles, which you call Live Activities.
        if sideBubbles(hiding: []) != .none {
            let hidden = island.bubblesHidden
            menu.addItem(.closure(hidden ? "Show Live Activities" : "Hide Live Activities") { [weak self] in
                if hidden { self?.island.showBubbles() } else { self?.island.hideBubbles() }
            })
        }
        menu.addItem(.closure("Full-Screen Player", enabled: nowPlaying.item != nil) { [weak self] in
            self?.fullScreenPlayer.open()
        })
        menu.addItem(.closure("Settings…") { [weak self] in self?.openSettings() })
        menu.addItem(.separator())
        menu.addItem(.closure("Quit Brim") { NSApp.terminate(nil) })
        return menu
    }

    /// Keep-awake's lengths (your fix round, 2026-09-30): the coffee in the tab row opens this, and it's the pill's
    /// right-click submenu. While it's on: when it ends on top, then the lengths (one starts over from now), Turn Off.
    func makeKeepAwakeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if keepAwake.isOn {
            menu.addItem(.closure(keepAwake.status, enabled: false) {})
            menu.addItem(.separator())
        }
        for minutes in KeepAwakeRules.choices {
            menu.addItem(.closure(KeepAwakeRules.label(minutes: minutes)) { [weak self] in
                self?.keepAwake.start(minutes: minutes)
            })
        }
        if keepAwake.isOn {
            menu.addItem(.separator())
            menu.addItem(.closure("Turn Off") { [weak self] in self?.keepAwake.stop() })
        }
        return menu
    }

    #if DEBUG
    /// Debug checks drive the island window directly.
    var debugIslandWindow: IslandWindowController { islandWindow }
    #endif

    /// The bubbles beside the resting pill; `hiding: []` asks what would show if you hadn't swiped any away.
    private func sideBubbles(hiding: Set<BubbleSide>) -> SideBubbles {
        IslandSides.current(surface: island.surface, timer: timer, calendar: calendar, keepAwake: keepAwake.isOn,
                            hiding: hiding)
    }

    private var islandActions: IslandActions {
        IslandActions(
            openSettings: { [weak self] in self?.openSettings() },
            openFullScreenPlayer: { [weak self] in self?.fullScreenPlayer.open() },
            quit: { NSApp.terminate(nil) },
            keepAwakeMenu: { [weak self] in
                // At the pointer, like a right-click; on the next turn, so the click finishes first.
                DispatchQueue.main.async {
                    guard let menu = self?.makeKeepAwakeMenu() else { return }
                    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                }
            }
        )
    }
}

#if DEBUG
extension AppEnvironment {
    /// Debug only: `--queue-render <png>` draws the full-screen player with the queue showing, in a window placed off
    /// every screen (nothing appears on yours), after 4 s, and saves it. Brim quits after.
    func renderQueueIfRequested() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--queue-render"), flag + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[flag + 1])
        // `--lyrics`: the lyrics side instead of the queue. Your own choice is put back before Brim quits.
        let saved = (islandSettings.fullScreenQueue, islandSettings.fullScreenLyrics)
        islandSettings.fullScreenQueue = !args.contains("--lyrics")
        islandSettings.fullScreenLyrics = true
        let view = FullScreenPlayerView(nowPlaying: nowPlaying, lyrics: lyrics, hud: hud, modes: playerModes,
                                        settings: islandSettings, actions: FullScreenActions(close: {}), outputs: audioOutputs,
                                        queue: queue, history: history)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1512, height: 945), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        Task { @MainActor in
            // `--as-spotify`: Spotify's own current song (from its scripting) shown as Now Playing, so the queue
            // asks Spotify; nothing is played or changed.
            if args.contains("--as-spotify"), let song = await playerControls.spotifyAnnouncementByScript(), let title = song.title {
                nowPlaying.debugPretend(NowPlaying(title: title, artist: song.artist, album: song.album,
                                                   bundleIdentifier: "com.spotify.client", isPlaying: true,
                                                   duration: song.duration, elapsed: 30, timestamp: .now))
            }
            // `--as-music`: Apple Music's current song (read, nothing played), as if started 90 s in.
            if args.contains("--as-music") {
                var error: NSDictionary?
                let read = NSAppleScript(source: "tell application id \"com.apple.Music\" to get {name, artist, album, duration} of current track")?
                    .executeAndReturnError(&error)
                if let read, read.numberOfItems == 4, let title = read.atIndex(1)?.stringValue {
                    nowPlaying.debugPretend(NowPlaying(title: title, artist: read.atIndex(2)?.stringValue, album: read.atIndex(3)?.stringValue,
                                                       bundleIdentifier: "com.apple.Music", isPlaying: true,
                                                       duration: read.atIndex(4)?.doubleValue, elapsed: 90, timestamp: .now))
                }
            }
            try? await Task.sleep(for: .seconds(4))
            if let content = window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out)
            }
            (self.islandSettings.fullScreenQueue, self.islandSettings.fullScreenLyrics) = saved
            NSApp.terminate(nil)
        }
    }
}
#endif

#if DEBUG
extension AppEnvironment {
    /// Island (music page), then each Settings page, then the full-screen player; writes AXDump's text to `file`.
    func runAXDump(into file: String) {
        var text = ""
        let after = { (seconds: Double, work: @escaping () -> Void) in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
        after(2) { [self] in
            island.open(page: .music)
            islandWindow.debugHold(for: 4)
        }
        after(2.8) { [self] in AXDump.warm([islandWindow.debugPanel]) }
        after(3.5) { [self] in
            text += "##### ISLAND (open, music)\n" + AXDump.text(for: [islandWindow.debugPanel])
            openSettings()
        }
        after(5) { [self] in
            guard let window = NSApp.windows.first(where: { $0.title == "Brim Settings" }),
                  let table = Self.firstTable(in: window.contentView) else {
                text += "##### SETTINGS: no sidebar found\n"; return
            }
            let rows = table.numberOfRows
            for row in 0..<rows {
                after(Double(row) * 0.6) {
                    table.selectRowIndexes([row], byExtendingSelection: false)
                    after(0.45) { text += "##### SETTINGS row \(row)\n" + AXDump.text(for: [window]) }
                }
            }
            after(Double(rows) * 0.6 + 0.8) { [self] in
                window.close()
                fullScreenPlayer.open()
                after(0.8) { AXDump.warm(NSApp.windows) }
                after(1.6) { [self] in
                    text += "##### FULL SCREEN\n" + AXDump.text(for: NSApp.windows.filter { $0.isVisible && $0 !== islandWindow.debugPanel })
                    try? text.write(toFile: file, atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private static func firstTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        for sub in view.subviews { if let found = firstTable(in: sub) { return found } }
        return nil
    }
}
#endif


import SwiftUI
import BrimCore

/// Everything drawn in the island panel.
/// The panel is always `IslandMetrics.panelSize`; this view grows and shrinks the island's shape inside it.
public struct IslandRootView: View {
    let coordinator: IslandCoordinator
    let nowPlaying: NowPlayingStore
    let hud: HUDStore
    let lyrics: LyricsStore
    let modes: PlayerModesStore
    let settings: IslandSettings
    let actions: IslandActions
    let outputs: AudioOutputsStore?
    let battery: BatteryStore?
    let headphones: HeadphonesStore?
    let calendar: CalendarStore?
    let timer: TimerStore?
    let keepAwake: KeepAwakeStore?
    /// One-time tips under the open island (2026-11-11). Nil: none (tests, benches).
    let tips: TipsStore?
    let geometryStore: IslandDisplayGeometryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    public init(coordinator: IslandCoordinator, nowPlaying: NowPlayingStore, hud: HUDStore, lyrics: LyricsStore,
                modes: PlayerModesStore, settings: IslandSettings, actions: IslandActions, outputs: AudioOutputsStore? = nil,
                battery: BatteryStore? = nil, headphones: HeadphonesStore? = nil, calendar: CalendarStore? = nil,
                timer: TimerStore? = nil, keepAwake: KeepAwakeStore? = nil, tips: TipsStore? = nil,
                geometry: IslandDisplayGeometryStore = IslandDisplayGeometryStore()) {
        self.tips = tips
        self.calendar = calendar
        self.timer = timer
        self.keepAwake = keepAwake
        self.outputs = outputs
        self.battery = battery
        self.headphones = headphones
        self.coordinator = coordinator
        self.nowPlaying = nowPlaying
        self.hud = hud
        self.lyrics = lyrics
        self.modes = modes
        self.settings = settings
        self.actions = actions
        self.geometryStore = geometry
    }

    public var body: some View {
        @Bindable var settings = settings
        let surface = coordinator.surface
        let appearance = settings.appearance
        let geometry = geometryStore.value
        // The slim line's Live Activity marks (your pick A): only while it shows.
        let marks = surface == .slim
            ? IslandSides.slimMarks(timer: timer, calendar: calendar, keepAwake: keepAwake?.isOn ?? false) : .none
        let slimParts = IslandMetrics.SlimParts(line: coordinator.slimCarriesMusic, dot: marks.left, bar: marks.right != nil)
        let size = IslandMetrics.size(for: surface, appearance: appearance, agendaRows: calendar?.agenda.count ?? 0,
                                      timerRows: min(timer?.items.count ?? 0, 2), slim: slimParts, geometry: geometry)
        let sides = IslandSides.current(surface: surface, timer: timer, calendar: calendar, keepAwake: keepAwake?.isOn ?? false,
                                        hiding: coordinator.hiddenBubbles)

        ZStack(alignment: .top) {
            // Drawn first and masked to outside the pill, so they pull out from behind it (decision 8).
            SideBubblesLayer(sides: sides, appearance: appearance, timer: timer, calendar: calendar,
                             keepAwake: keepAwake, geometry: geometry)
            if surface != .hidden {
                // One view for every visible state, so the shape morphs between them instead of popping:
                // slim line ↔ pill ↔ HUD ↔ open island.
                content(for: surface, appearance: appearance, geometry: geometry)
                    .frame(width: size.width, height: size.height)
                    .overlay(alignment: .top) { hudBanner(on: surface, appearance: appearance) }
                    .overlay(alignment: .top) { glanceBanner(on: surface, appearance: appearance) }
                    .islandSurface(appearance, for: surface, geometry: geometry)
                    .contextMenu {
                        if showsLyricsTiming(on: surface) {
                            LyricsTimingMenuItems(lyrics: lyrics, place: .island)
                            Divider()
                        }
                        if let timer {
                            if timer.canStartAnother {
                                Menu("Start Timer") {
                                    ForEach(TimerState.presets, id: \.self) { minutes in
                                        Button("\(minutes) min") { timer.start(minutes: minutes) }
                                    }
                                }
                            }
                            if !timer.items.isEmpty {
                                Button(timer.items.count == 1 ? "Cancel Timer" : "Cancel All Timers", action: timer.cancelAll)
                            }
                            Divider()
                        }
                        if let keepAwake {
                            // The same lengths as the coffee's menu and the pill's right-click (0.13.1).
                            Menu("Keep Mac Awake") {
                                if keepAwake.isOn {
                                    Text(keepAwake.status)
                                    Divider()
                                }
                                ForEach(KeepAwakeRules.choices, id: \.self) { minutes in
                                    Button(KeepAwakeRules.label(minutes: minutes)) { keepAwake.start(minutes: minutes) }
                                }
                                if keepAwake.isOn {
                                    Divider()
                                    Button("Turn Off", action: keepAwake.stop)
                                }
                            }
                        }
                        Toggle("Keep Music Visible", isOn: $settings.keepPillVisible)
                        Button("Full-Screen Player", action: actions.openFullScreenPlayer)
                            .disabled(nowPlaying.item == nil)
                        Button("Settings…", action: actions.openSettings)
                        Divider()
                        Button("Quit Brim", action: actions.quit)
                    }
                    // A tip peeks out from under the open island, when there's room for it in the window.
                    .overlay(alignment: .bottom) {
                        if let tip = tips?.current, surface.isExpanded,
                           IslandMetrics.topGap(for: surface, appearance: appearance) + size.height + TipBubble.room
                            <= IslandMetrics.panelSize.height {
                            TipBubble(tip: tip)
                                .offset(y: TipBubble.height + 8)  // just under the island's bottom edge
                                .transition(reduceMotion ? .opacity
                                            : .opacity.combined(with: .offset(y: -14)).combined(with: .scale(scale: 0.9, anchor: .top)))
                        }
                    }
                    .padding(.top, IslandMetrics.topGap(for: surface, appearance: appearance))
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.9, anchor: .top).combined(with: .opacity))
            }
        }
        .frame(width: IslandMetrics.panelSize.width, height: IslandMetrics.panelSize.height, alignment: .top)
        // One spring for every change: slim ↔ compact ↔ expanded morph, appear, disappear (PRD §7.1).
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.15), value: surface)
        .animation(.easeInOut(duration: 0.2), value: hud.showing)
        .animation(.easeInOut(duration: 0.2), value: coordinator.banner)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.2), value: tips?.current)
        // Tips: one per opening, for what's on screen; closing the island puts it away.
        .onChange(of: surface) { _, now in
            guard let tips else { return }
            if now.isExpanded, !coordinator.spotlit {
                // Asked again before each tip: the tab, the song and the lyrics can all change while it's open.
                tips.islandOpened { [coordinator, nowPlaying] in
                    let surface = coordinator.surface
                    let page: ExpandedPage = if case .expanded(let page) = surface { page } else { .music }
                    return TipsStore.Showing(page: page, hasSong: nowPlaying.item != nil,
                                             lyricsShowing: showsLyricsTiming(on: surface))
                }
            } else {
                tips.islandClosed()
            }
        }
        // The pull-out: a spring with a little bounce, so the bubble overshoots and settles (decision 8).
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.25), value: sides)
        .environment(outputs)
        .environment(tips)
    }

    @ViewBuilder
    private func content(for surface: IslandSurface, appearance: IslandAppearance,
                         geometry: IslandDisplayGeometry) -> some View {
        switch surface {
        case .hidden:
            EmptyView()
        case .slim:
            SlimLineView(appearance: appearance, tint: nowPlaying.artworkTint, isPlaying: nowPlaying.isPlaying,
                         showsLine: coordinator.slimCarriesMusic,
                         marks: IslandSides.slimMarks(timer: timer, calendar: calendar, keepAwake: keepAwake?.isOn ?? false),
                         timer: timer, calendar: calendar, geometry: geometry)
                .transition(contentTransition)
        case .compact(.nowPlaying):
            CompactMediaView(store: nowPlaying).transition(contentTransition)
        case .compact(.battery):
            if let battery {
                BatteryNoticeView(store: battery).transition(contentTransition)
            }
        case .compact(.calendar):
            if let calendar {
                CalendarReminderView(store: calendar).transition(contentTransition)
            }
        case .compact(.timer):
            if let timer { TimerPillView(timer: timer).transition(contentTransition) }
        case .compact(.keepAwake):
            KeepAwakePillView(store: keepAwake).transition(contentTransition)
        case .compact(.resting):
            RestingBrimView(awake: coordinator.spotlit, appearance: appearance).transition(contentTransition)
        case .compact(.timerNotice):
            if let timer { TimerNoticeView(timer: timer).transition(contentTransition) }
        case .compact(.timerDone):
            if let timer { TimerDoneView(timer: timer).transition(contentTransition) }
        case .compact(.headphones):
            if let headphones {
                HeadphonesNoticeView(store: headphones).transition(shrinkAwayTransition)
            }
        case .compact(.keptMusic):
            KeptMusicView(store: nowPlaying, appearance: appearance).transition(contentTransition)
        case .compact(.hud(.volume)):
            if let level = hud.appVolume {
                LevelHUDView(appVolume: level, app: hud.appVolumeName, style: settings.hudStyle, appearance: appearance)
                    .transition(contentTransition)
            } else if let volume = hud.volume {
                LevelHUDView(volume: volume, style: settings.hudStyle, appearance: appearance).transition(contentTransition)
            }
        case .compact(.hud(.brightness)):
            if let brightness = hud.brightness {
                LevelHUDView(brightness: brightness, style: settings.hudStyle, appearance: appearance).transition(contentTransition)
            }
        case .expanded(let page):
            // One open island with tabs: the tab row stays put while the page under it changes.
            VStack(spacing: 0) {
                // The coffee opens keep-awake's lengths (your fix round, 2026-09-30); the app shows the menu.
                TabBar(selected: page, onSelect: coordinator.showPage, keepAwake: keepAwake?.isOn,
                       keepAwakeHelp: keepAwake?.status ?? "", onKeepAwake: actions.keepAwakeMenu)
                    .padding(.top, 6)
                    .frame(height: IslandMetrics.tabBarHeight, alignment: .top)
                ZStack {
                    switch page {
                    case .music:
                        if nowPlaying.item != nil {
                            ExpandedMediaView(store: nowPlaying, lyrics: lyrics, modes: modes, settings: settings,
                                              openFullScreen: actions.openFullScreenPlayer)
                                .transition(contentTransition)
                        } else if let reason = nowPlaying.unavailableReason {
                            NowPlayingUnavailableView(reason: reason, retry: nowPlaying.retryHelper)
                                .transition(contentTransition)
                        } else {
                            MusicEmptyView().transition(contentTransition)
                        }
                    case .timers:
                        if let timer { TimersTabView(timer: timer).transition(contentTransition) }
                    case .calendar:
                        CalendarTabView(actions: actions, calendar: calendar, showsEvent: settings.calendarEnabled)
                            .transition(contentTransition)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .transition(contentTransition)
        }
    }

    /// Lyric timing joins the right-click menu while the open island shows timed lyrics.
    private func showsLyricsTiming(on surface: IslandSurface) -> Bool {
        surface == .expanded(.music) && settings.lyricsEnabled && settings.lyricsModeOn && lyrics.canAdjustTiming
    }

    /// Content follows the shape, like the iPhone's Dynamic Island: the old content leaves quickly (0.1 s), the
    /// new one arrives a beat later (80 ms) and grows in slightly, so text never squeezes while the island
    /// changes shape. Transitions only; nothing runs at rest. Reduce Motion: a plain fade.
    /// The AirPods notice: as it ends, its contents shrink a little and fade while the island narrows back to the pill.
    private var shrinkAwayTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: AnyTransition.opacity.combined(with: .scale(scale: 0.96, anchor: .center))
                .animation(.easeOut(duration: 0.22).delay(0.08)),
            removal: AnyTransition.opacity.combined(with: .scale(scale: 0.85, anchor: .center))
                .animation(.easeIn(duration: 0.2)))
    }

    private var contentTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: AnyTransition.opacity.combined(with: .scale(scale: 0.96, anchor: .center))
                .animation(.easeOut(duration: 0.22).delay(0.08)),
            removal: AnyTransition.opacity.animation(.easeIn(duration: 0.1)))
    }

    /// While the island is open, a volume or brightness change shows as a slim slider at its top,
    /// instead of collapsing the island you're using.
    @ViewBuilder
    private func hudBanner(on surface: IslandSurface, appearance: IslandAppearance) -> some View {
        if case .expanded = surface, let kind = hud.showing, let banner = banner(for: kind) {
            FillBar(level: banner.level, dimmed: banner.dimmed, symbol: banner.symbol, label: nil,
                    track: appearance.isSolidBlack ? .white.opacity(0.18) : .black.opacity(0.35))
                .frame(width: 220, height: 24)
                // A solid base, so the artwork or text underneath never shows through the track.
                .background { bannerBase(appearance) }
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// A glance while the island is open (docs/05-interaction-model.md): the same notice as on the pill, as a
    /// banner over the top row, on a solid base. The island stays open under it.
    @ViewBuilder
    private func glanceBanner(on surface: IslandSurface, appearance: IslandAppearance) -> some View {
        if surface.isExpanded, hud.showing == nil, let kind = coordinator.banner {
            glanceContent(kind)
                .frame(width: IslandMetrics.glanceWidth - 20, height: IslandMetrics.pillSize(appearance: appearance).height)
                .background { bannerBase(appearance) }
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func glanceContent(_ kind: IslandActivity.Kind) -> some View {
        switch kind {
        case .battery: if let battery { BatteryNoticeView(store: battery) }
        case .headphones: if let headphones { HeadphonesNoticeView(store: headphones) }
        case .calendar: if let calendar { CalendarReminderView(store: calendar, onJoin: { openURL($0) }) }
        case .timerNotice: if let timer { TimerNoticeView(timer: timer) }
        case .timerDone:
            if let timer {
                // Ends while the island is open: the banner stays until you click it. Its buttons are live here.
                TimerDoneView(timer: timer, onNext: timer.startNext, onStop: timer.stopAlarm)
                    .contentShape(Capsule())
                    .onTapGesture { timer.stopAlarm() }
            }
        default: EmptyView()
        }
    }

    @ViewBuilder
    private func bannerBase(_ appearance: IslandAppearance) -> some View {
        switch appearance {
        case .black, .blackPill: Capsule().fill(Color.black)
        case .liquidGlass: Capsule().fill(.thinMaterial)
        }
    }

    private func banner(for kind: HUDKind) -> (level: Double, dimmed: Bool, symbol: String)? {
        switch kind {
        case .volume:
            if let level = hud.appVolume { (level, false, level <= 0.001 ? "speaker.slash.fill" : "music.note") }
            else { hud.volume.map { ($0.level, $0.isMuted, $0.hudSymbol) } }
        case .brightness: hud.brightness.map { ($0.level, false, $0.symbolName) }
        }
    }
}

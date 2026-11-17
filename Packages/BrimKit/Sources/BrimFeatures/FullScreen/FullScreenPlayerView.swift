import SwiftUI
import BrimCore

/// What the full-screen player can ask the app to do.
public struct FullScreenActions {
    public var close: () -> Void

    public init(close: @escaping () -> Void) {
        self.close = close
    }
}

/// The full-screen player (PRD F6), after your Apple Music screenshot:
/// art, title, progress, and controls on the left; synced lyrics on the right; a background from the art's colours.
/// With no lyrics, the left column moves to the centre.
public struct FullScreenPlayerView: View {
    let nowPlaying: NowPlayingStore
    let lyrics: LyricsStore
    let hud: HUDStore
    let modes: PlayerModesStore
    let settings: IslandSettings
    let actions: FullScreenActions
    /// Music's or Spotify's own volume for the slider; nil: the Mac's.
    let appVolume: AppVolumeStore?
    let outputs: AudioOutputsStore?
    let queue: QueueStore?
    let history: HistoryStore?

    public init(nowPlaying: NowPlayingStore, lyrics: LyricsStore, hud: HUDStore, modes: PlayerModesStore,
                settings: IslandSettings, actions: FullScreenActions, outputs: AudioOutputsStore? = nil,
                queue: QueueStore? = nil, history: HistoryStore? = nil, appVolume: AppVolumeStore? = nil) {
        self.appVolume = appVolume
        self.outputs = outputs
        self.queue = queue
        self.history = history
        self.nowPlaying = nowPlaying
        self.lyrics = lyrics
        self.modes = modes
        self.hud = hud
        self.settings = settings
        self.actions = actions
    }

    public var body: some View {
        GeometryReader { proxy in
            // Apple Music's halves (FullScreenLayout): the cover and controls centred in the left half, the lyrics or
            // queue from just right of the middle. Alone, the left side moves to the centre.
            let layout = FullScreenLayout(size: proxy.size)
            let hasSide = showsQueue || showsLyricsColumn
            ZStack(alignment: .topLeading) {
                FullScreenBackground(colors: nowPlaying.artworkColors)
                NowPlayingColumn(store: nowPlaying, modes: modes, layout: layout, settings: settings)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(x: hasSide ? layout.columnCenterX - proxy.size.width / 2 : 0)
                    .animation(.spring(duration: 0.5, bounce: 0.1), value: hasSide)
                ZStack(alignment: .leading) {
                    if let queue, showsQueue {
                        QueueColumn(queue: queue, nowPlaying: nowPlaying, history: history, modes: modes.modes)
                            .frame(width: layout.lyricsWidth, height: proxy.size.height * 0.72)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    } else if showsLyricsColumn {
                        Group {
                            if let note = lyricsNote {
                                // Said plainly instead of the side vanishing under a lit Lyrics button (your report,
                                // 2026-10-29: it looked broken).
                                Text(note).font(.system(size: 22 * layout.textScale, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            } else {
                                LyricsColumn(lyrics: lyrics, sweep: settings.lyricsSweep, size: layout.lyricsSize,
                                             spacing: layout.lyricsSpacing, onSeek: { time in
                                                 // Fixing the timing: a click lines the lyrics up with that line.
                                                 if lyrics.syncing == .fullScreen { lyrics.syncLine(shownAt: time) }
                                                 else { nowPlaying.seek(to: time) }
                                             })
                                    // One "Lyrics" group, after the controls, so VoiceOver doesn't read lines between
                                    // the buttons (the VoiceOver pass, 2026-11-17).
                                    .accessibilityElement(children: .contain)
                                    .accessibilityLabel("Lyrics")
                                    .accessibilitySortPriority(-1)
                                    .overlay(alignment: .bottom) {
                                        if lyrics.syncing == .fullScreen {
                                            LyricsSyncBar(lyrics: lyrics, large: true)
                                                .frame(maxWidth: 520)
                                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                                        }
                                    }
                                    .animation(.easeOut(duration: 0.2), value: lyrics.syncing)
                                    .onDisappear { lyrics.endSync(in: .fullScreen) }
                            }
                        }
                        .frame(width: layout.lyricsWidth, height: proxy.size.height * 0.72)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .padding(.leading, layout.sideX)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .animation(.spring(duration: 0.5, bounce: 0.1), value: showsLyricsColumn)
                .animation(.spring(duration: 0.5, bounce: 0.1), value: showsQueue)

                // Corner insets measured from Apple Music's full-screen player (your screenshots, 2026-10-29).
                GlassCircleButton(symbol: "xmark", label: "Close full-screen player", action: actions.close)
                    .padding(.leading, 15).padding(.top, 12)
            }
            .overlay(alignment: .topTrailing) {
                GlassVolumeSlider(hud: hud, app: appVolume).padding(.trailing, 10).padding(.top, 12)
                    // Whose volume: asked as it opens and when the song or the app changes.
                    .task(id: nowPlaying.item?.identity) { appVolume?.refresh() }
            }
            .overlay(alignment: .bottomTrailing) {
                // Lyrics and Queue side by side, like Apple Music's (your screenshot, 2026-10-29): one lights at a time;
                // clicking the lit one hides the right side and the art moves to the centre.
                // One glass shell with both, like Apple Music's (your screenshot, 2026-10-29).
                let lyricsOn = settings.fullScreenLyrics && !showsQueue
                GlassSegments(segments: [
                    settings.lyricsEnabled ? GlassSegments.Segment(symbol: lyricsOn ? "quote.bubble.fill" : "quote.bubble",
                                                                   label: "Lyrics", isOn: lyricsOn) {
                        settings.fullScreenLyrics = !lyricsOn
                        settings.fullScreenQueue = false
                    } : nil,
                    queue != nil ? GlassSegments.Segment(symbol: "list.bullet", label: "Queue", isOn: showsQueue) {
                        settings.fullScreenQueue.toggle()
                    } : nil,
                ].compactMap { $0 })
                // Tucked into the corner like Apple Music's (your screenshots, 2026-10-29).
                .padding(.trailing, 11).padding(.bottom, 12)
            }
        }
        .environment(\.colorScheme, .dark)
        .environment(outputs)
        .ignoresSafeArea()
    }

    private var showsQueue: Bool { queue != nil && settings.fullScreenQueue }

    /// PRD F6: "With no lyrics, the artwork is centered", and the lyrics switch off does the same.
    /// While looking them up, keep the column (no jump).
    private var showsLyricsColumn: Bool {
        guard settings.fullScreenLyrics else { return false }
        return switch lyrics.status {
        case .loading, .notFound, .offline, .rateLimited, .failed: true
        case .ready: lyrics.lyrics != .instrumental
        default: false
        }
    }

    /// Why there are no lyrics to show, when there aren't.
    private var lyricsNote: String? {
        switch lyrics.status {
        case .notFound: "No lyrics for this song yet."
        case .offline: "Lyrics are offline. They'll be back when you are."
        case .rateLimited: "Lyrics in a moment."
        case .failed: "Lyrics couldn't be loaded."
        default: nil
        }
    }
}

/// Art, title and artist (gliding if long), progress, and controls.
private struct NowPlayingColumn: View {
    let store: NowPlayingStore
    let modes: PlayerModesStore
    let layout: FullScreenLayout
    let settings: IslandSettings
    /// The swipe on the controls, while your fingers move and as it lands (SidePaging).
    @State private var paging = SidePager()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let pausedScale: CGFloat = 0.74

    private func switchSides(to buttons: SideButtons) {
        guard buttons != settings.sideButtons else { return }
        Usage.note("sides.dot.fullScreen")
        paging.reset()
        withAnimation(SideButtonsSwitch.animation(reduceMotion: reduceMotion)) { settings.sideButtons = buttons }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ArtworkView(image: store.artwork, size: layout.artSize, cornerRadius: 16)
                .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
                // Paused, the cover steps back to 74% around its centre and comes forward again on play, as Apple Music's
                // does (measured in your video, 2026-10-07: about 400 → 294 pt). The title and controls stay put.
                .scaleEffect(store.isPlaying ? 1 : Self.pausedScale)
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.82),
                           value: store.isPlaying)
                // Centred over the title and controls, which are wider than the cover on a big screen (as on Apple's).
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                // Long lines loop like Apple Music's (your video, 2026-10-29): a gap of ~3.5 × the text size, fading
                // out just left of the column.
                MarqueeText(trigger: store.item?.identity, gap: 84, bleed: 30) {
                    Text(store.item?.title ?? "").font(.system(size: 24, weight: .bold))
                }
                MarqueeText(trigger: store.item?.identity, gap: 64, bleed: 22) {
                    Text(store.item?.artist ?? "").font(.system(size: 18)).foregroundStyle(.secondary)
                }
            }
            if let item = store.item {
                ProgressRow(item: item, large: true, onSeek: store.seek(to:))
            }
            // Swipe sideways (or click the dots) to switch the pair beside the controls, as on the island (your ask,
            // 2026-10-30): Shuffle & Repeat ↔ ★ & Output. The same setting, so both places show the same pair. The
            // buttons follow your fingers (2026-11-16).
            TransportRow(store: store, modes: modes, large: true, sideButtons: settings.sideButtons,
                         pagePosition: paging.position, spacing: layout.controlSpacing)
                .onSidewaysPaging(changed: { paging.follow($0, on: settings.sideButtons) },
                                  ended: { dx, speed in
                                      paging.land(dx, speed: speed, settings: settings, reduceMotion: reduceMotion) {
                                          Usage.note("sides.swipe.fullScreen")
                                      }
                                  })
                .overlay(alignment: .bottom) {
                    SidePageDots(selected: settings.sideButtons, position: paging.position) { switchSides(to: $0) }
                        .offset(y: 22)
                }
                .frame(maxWidth: .infinity)
        }
        .frame(width: layout.columnWidth)
        .foregroundStyle(.white)
    }
}

/// Synced lyrics, Apple Music–style: the current line bright and big; the next lines dimmer and more blurred
/// the further away they are; past lines fade out upward. Click a line to jump there.
struct LyricsColumn: View {
    let lyrics: LyricsStore
    /// Letters of the current line light up as they're sung (Settings → Media & Lyrics).
    var sweep = false
    /// The lines' text size: 34 pt on a Mac screen, more on a TV (FullScreenLayout).
    var size: CGFloat = 34
    /// Room between lines, so the line being sung stands on its own (your video of Apple Music, 2026-10-07: ~47 pt there).
    var spacing: CGFloat = 44
    let onSeek: (TimeInterval) -> Void
    /// Each line's height. Positions are added up from these (a line's size doesn't change as it moves,
    /// so each line can move on its own without disturbing the measurement).
    @State private var rowHeights: [Int: CGFloat] = [:]
    /// Where you scrolled the list to (your Apple Music video, 2026-10-01; 0.18.1); nil while it follows the song.
    @State private var browseShift: CGFloat?
    /// The line under the pointer: lit while you browse.
    @State private var hovered: Int?
    @State private var browseEnd: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch (lyrics.status, lyrics.lyrics) {
            case (.ready, .synced(let lines)?):
                synced(lines)
            case (.ready, .plain(let text)?):
                ScrollView(.vertical, showsIndicators: false) {
                    Text(text)
                        .font(.system(size: 26 * size / 34, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineSpacing(10 * size / 34)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 80)
                }
            default:
                Text("Finding lyrics…")
                    .font(.system(size: 26 * size / 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .mask(edgeFade)
        .contextMenu {
            if lyrics.canAdjustTiming { LyricsTimingMenuItems(lyrics: lyrics, place: .fullScreen) }
        }
        .onAppear { lyrics.beginDisplay() }
        .onDisappear { lyrics.endDisplay() }
    }

    /// All lines in one stack, the current line kept 30% from the top (like Apple Music). When the line
    /// changes, the line leaving moves first and each line below follows a moment later, so the list stretches and
    /// settles like Apple Music's (see `motion`). A plain stack rather than a scroll view: exact control over the
    /// motion, and it renders offscreen for tests.
    private func synced(_ lines: [LyricLine]) -> some View {
        // Read here, in `body`, and handed to the closure below: state read only inside a GeometryReader's closure isn't
        // tracked, so the closure kept an old copy without the heights. Each line change then moved the lines 26 pt
        // instead of a whole line, leaving the current line lower and lower (found 2026-10-01 by capturing Brim's
        // frames; a debug probe that read the heights on every pass had hidden it).
        let heights = rowHeights
        let reduceMotion = reduceMotion
        let browsed = browseShift
        let lit = browsed == nil ? nil : hovered
        return GeometryReader { box in
            let current = lyrics.currentIndex ?? 0
            let anchor = box.size.height * 0.3
            // Following the song: the current line at the anchor. Browsing: where you scrolled to.
            let shift = browsed ?? anchor - Self.top(of: current, heights: heights, spacing: spacing)
            let lastTop = Self.top(of: lines.count - 1, heights: heights, spacing: spacing)
            ZStack(alignment: .topLeading) {
                // The column's own area hears the scroll (the stack below is taller than the column).
                Color.clear
                    .frame(width: box.size.width, height: box.size.height)
                    .onScrollWheel { browse(by: $0, from: shift, anchor: anchor, lastTop: lastTop) }
                VStack(alignment: .leading, spacing: spacing) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        LyricRow(text: line.text, size: size, distance: distance(of: index), lyrics: lyrics, sweep: sweep,
                                 browsing: browsed != nil, lit: lit == index)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                                // Only real changes count, so measuring never feeds back into another layout pass.
                                if abs((rowHeights[index] ?? -1) - height) > 0.5 { rowHeights[index] = height }
                            }
                            .contentShape(Rectangle())
                            .onHover { inside in
                                if inside { hovered = index } else if hovered == index { hovered = nil }
                            }
                            .onTapGesture {
                                onSeek(line.time)
                                stopBrowsing()  // the list follows the song again, from the line you picked
                            }
                            .offset(y: shift)
                            .animation(Self.motion(distance: index - current, reduceMotion: reduceMotion),
                                       value: lyrics.currentIndex)
                    }
                }
                // The stack takes its full natural height (taller than the column; the offset and clip handle that).
                // Without this it was squeezed into the column's height, so every long line was cut to one line + "…".
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .clipped()
        .onChange(of: lines) { stopBrowsing(animated: false) }  // another song: follow it
    }

    /// You scrolled over the lyrics: the list moves with your fingers (no spring), between the first and last lines,
    /// and stops following the song until `LyricsBrowse.returnAfter` seconds pass without a scroll.
    private func browse(by delta: CGFloat, from shift: CGFloat, anchor: CGFloat, lastTop: CGFloat) {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            browseShift = LyricsBrowse.clamped(shift + delta, anchor: anchor, lastTop: lastTop)
        }
        browseEnd?.cancel()
        browseEnd = Task {
            try? await Task.sleep(for: .seconds(LyricsBrowse.returnAfter))
            guard !Task.isCancelled else { return }
            stopBrowsing()
        }
    }

    /// Back to following the song: the list glides to the line being sung, and the blur comes back.
    private func stopBrowsing(animated: Bool = true) {
        browseEnd?.cancel()
        browseEnd = nil
        guard browseShift != nil else { return }
        hovered = nil
        guard animated else { return browseShift = nil }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: 0.5, dampingFraction: 1)) {
            browseShift = nil
        }
    }

    /// Where line `index` starts: the heights above it plus the gaps.
    static func top(of index: Int, heights: [Int: CGFloat], spacing: CGFloat) -> CGFloat {
        (0..<max(index, 0)).reduce(0) { $0 + (heights[$1] ?? 0) + spacing }
    }

    /// Apple Music's motion, measured frame by frame at 56 fps in your "Bookah effect" video (2026-10-01, two line
    /// changes): the line leaving moves first and each line below starts ~45 ms after the one above, so the gap
    /// between neighbours opens by ~20% of the distance they travel and closes again, the "pull" (65 of 310 px, and
    /// 84 of 451). Each line rides a critically damped spring, ~0.5 s, no overshoot: the "bounce" you see is that
    /// gap closing. (0.13.2 used 18 ms and 0.4 s from an earlier recording; it never showed, see LyricRow.) Only the
    /// lines on screen animate (3 above, 8 below). Reduce Motion: a short glide.
    static func motion(distance: Int, reduceMotion: Bool) -> Animation? {
        if reduceMotion { return .easeInOut(duration: 0.3) }
        guard (-3...8).contains(distance) else { return nil }
        let order = max(distance + 1, 0)  // the line leaving (−1) first, then the new line, then each one below
        return .spring(response: 0.5, dampingFraction: 1).delay(Double(order) * Self.stagger)
    }

    /// When the new current line is in place: its own delay plus the spring settling to under 1 pt. Its lit letters
    /// wait until then (an AppKit layer can't follow the glide).
    static var arrival: TimeInterval { stagger + 0.55 }

    /// The wait between one line and the next (~2.5 frames at 56 fps in your video).
    /// Debug builds: `--lyrics-stagger <seconds>` tries another value without rebuilding.
    static let stagger: Double = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let flag = args.firstIndex(of: "--lyrics-stagger"), flag + 1 < args.count, let value = Double(args[flag + 1]) {
            return value
        }
        #endif
        return 0.045
    }()

    /// Lines after the current one count up (1, 2, …); the current line is 0; past lines are negative.
    private func distance(of index: Int) -> Int {
        index - (lyrics.currentIndex ?? -1)
    }

    /// Lines fade out at the top and bottom edges instead of being cut.
    private var edgeFade: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                               .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}

private struct LyricRow: View {
    let text: String
    let size: CGFloat
    /// 0 = playing now; > 0 = coming up; < 0 = already sung.
    let distance: Int
    let lyrics: LyricsStore
    var sweep = false
    /// You're scrolling through the lyrics: every line sharp and readable.
    var browsing = false
    /// The line under the pointer while you browse: lit, as a click there jumps to it.
    var lit = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Only the line being sung sweeps; the rest are plain text (no timeline, no redraws).
        SweepLine(text: text.isEmpty ? "♪" : text, size: size, weight: .bold, color: .white, dim: 0.4,
                  clock: sweep && distance == 0 && !text.isEmpty ? lyrics.sweepClock : nil,
                  revealAfter: LyricsColumn.arrival)
            // Blur changes at once: animating it redraws blurred text every frame (measured, full-screen CPU). Scoped to
            // the blur alone. A `.transaction { $0.animation = nil }` here used to also freeze the line's own movement,
            // so every line jumped instead of gliding (your 0.13.2 test; found by capturing Brim's frames, 2026-10-01).
            .animation(nil) { $0.blur(radius: reduceMotion ? 0 : blur) }
            // No animation of its own: the dimming rides on the line's own spring and delay (LyricsColumn.motion), so
            // a line fades as it moves. A 0.35 s fade here (0.13.0–0.13.3) took over the line's movement too: SwiftUI
            // moves the text with the animation of its own latest change, so every line glided on that one fade, in
            // lockstep, with no pull (measured 2026-10-01: plain text rows staggered; these didn't).
            .opacity(opacity)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var opacity: Double {
        if browsing { return distance == 0 || lit ? 1 : 0.55 }
        return switch distance {
        case 0: 1
        case 1...: max(0.2, 0.5 - Double(distance - 1) * 0.08)
        default: 0.22
        }
    }

    private var blur: CGFloat {
        guard !browsing else { return 0 }
        return distance > 0 ? min(CGFloat(distance), 4) * 1.1 : 0
    }
}

/// A round glass button: close, and the lyrics switch (a white disc when it's on).
/// Two (or one) buttons in one glass capsule: the lit one sits in a light circle; clicking it again turns it off.
struct GlassSegments: View {
    struct Segment {
        let symbol: String
        let label: String
        let isOn: Bool
        let action: () -> Void
    }
    let segments: [Segment]

    var body: some View {
        // 76 x 38 pt like Apple Music's (measured from your screenshots, 2026-10-29).
        HStack(spacing: 2) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                Button(action: segment.action) {
                    // Apple Music's look (your screenshots): the lit one is a light pill with
                    // a dark glyph (Lyrics fills its bubble), the other a white outline glyph.
                    Image(systemName: segment.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(segment.isOn ? Color(red: 0.24, green: 0.16, blue: 0.12) : .white)
                        .frame(width: 34, height: 32)
                        .background(segment.isOn ? Color(white: 0.93) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(segment.isOn ? "Hide \(segment.label.lowercased())" : "Show \(segment.label.lowercased())")
                .accessibilityAddTraits(segment.isOn ? .isSelected : [])
            }
        }
        .padding(3)
        .brimGlass(in: Capsule())
        .animation(.spring(response: 0.3, dampingFraction: 1), value: segments.map(\.isOn))
    }
}

struct GlassCircleButton: View {
    let symbol: String
    let label: String
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isOn ? .black : .white)
                .frame(width: 38, height: 38)
                .background(isOn ? Color.white : Color.clear, in: Circle())
                .brimGlass(in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The volume in a glass capsule, top right, drawn like macOS's own volume slider (your screenshot 7, measured):
/// a thin light track, a white pill knob, the speaker on the right. Click or drag anywhere on the track.
/// While Music or Spotify plays, it's that app's own volume, like Apple Music's slider (your find, 2026-11-17): other
/// apps keep the Mac's volume. Otherwise the Mac's output volume; outputs without one (some HDMI or USB) show it dimmed.
struct GlassVolumeSlider: View {
    let hud: HUDStore
    var app: AppVolumeStore?
    /// While dragging, the slider follows the pointer instead of waiting for CoreAudio's answer.
    @State private var dragging: Double?

    private static let trackWidth: CGFloat = 132
    private static let knob = CGSize(width: 24, height: 13)

    var body: some View {
        let appLevel = app?.level
        let muted = appLevel.map { $0 == 0 } ?? (hud.volume?.isMuted == true)
        let level = dragging ?? appLevel ?? (muted ? 0 : hud.volume?.level ?? 0)
        let adjustable = appLevel != nil || hud.volume?.isAdjustable != false
        HStack(spacing: 8) {
            track(level: level)
                .gesture(drag, including: adjustable ? .all : .none)
            // One speaker whose waves light up with the level (like macOS), so the icon never changes width.
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: muted ? nil : level)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 22, alignment: .leading)
        }
        .padding(.leading, 17).padding(.trailing, 11)
        .frame(height: 38)  // about 191 x 38 pt, like Apple Music's
        .brimGlass(in: Capsule())
        .opacity(adjustable ? 1 : 0.45)
        .help(appLevel == nil ? "" : "\(app?.player == .spotify ? "Spotify" : "Music")'s own volume: other apps keep the Mac's")
        // VoiceOver hears a real slider (the VoiceOver pass, 2026-11-17: it was a nameless kind of thing): "Spotify
        // volume, 30 percent, slider", and VO-arrows step it like the volume keys.
        .accessibilityRepresentation {
            Slider(value: Binding(get: { level }, set: { next in
                guard adjustable else { return }
                let stepped = LevelStep.next(from: appLevel ?? hud.volume?.level ?? 0, up: next > level, fine: false)
                if appLevel != nil { app?.set(stepped) } else { hud.setVolume(stepped) }
            }), in: 0...1) {
                Text(appLevel == nil ? "Volume" : "\(app?.player == .spotify ? "Spotify" : "Music") volume")
            }
            .accessibilityValue("\(Int((level * 100).rounded())) percent")
            .disabled(!adjustable)
        }
    }

    /// The fill runs to the knob's centre; the knob stays inside the track at both ends.
    private func track(level: Double) -> some View {
        let knobLeft = (Self.trackWidth - Self.knob.width) * level
        return ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.22)).frame(height: 6)
            Capsule().fill(.white.opacity(0.82)).frame(width: knobLeft + Self.knob.width / 2, height: 6)
            Capsule().fill(.white)
                .frame(width: Self.knob.width, height: Self.knob.height)
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                .offset(x: knobLeft)
        }
        .frame(width: Self.trackWidth, height: 24)  // the click target is taller than the thin track
        .contentShape(Rectangle())
        .animation(dragging == nil ? .easeOut(duration: 0.15) : nil, value: level)  // key presses glide, drags don't lag
    }

    /// A click jumps the knob to the pointer; a drag follows it.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let travel = Self.trackWidth - Self.knob.width
                let level = Double(min(max((value.location.x - Self.knob.width / 2) / travel, 0), 1))
                dragging = level
                if app?.level != nil { app?.set(level) } else { hud.setVolume(level) }
            }
            .onEnded { _ in dragging = nil }
    }
}

/// The background: the art's colours, deepened so white text stays readable. A still gradient underneath, and
/// `MovingBackground`'s drifting blobs on top (Core Animation). Black-and-white art gets a deep grey.
struct FullScreenBackground: View {
    let colors: [TintColor]

    var body: some View {
        let tones = (colors.isEmpty ? [TintColor(hue: 0, saturation: 0, brightness: 0.18)] : colors)
            .map { $0.background() }
            .map { Color(hue: $0.hue, saturation: $0.saturation, brightness: $0.brightness) }
        ZStack {
            Color.black
            LinearGradient(colors: [tones[0], tones[tones.count > 1 ? 1 : 0]], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [tones[tones.count > 2 ? 2 : 0].opacity(0.8), .clear],
                           center: .init(x: 0.8, y: 0.25), startRadius: 0, endRadius: 700)
            RadialGradient(colors: [tones[tones.count > 3 ? 3 : 0].opacity(0.7), .clear],
                           center: .init(x: 0.2, y: 0.85), startRadius: 0, endRadius: 650)
            MovingBackground(colors: colors)
            Color.black.opacity(0.18)
        }
        .ignoresSafeArea()
    }
}

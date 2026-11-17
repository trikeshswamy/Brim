import SwiftUI
import BrimCore

/// Wireframe "Expanded, music playing": art + title (or lyrics) + source app, progress, controls. 420 × 170 pt.
struct ExpandedMediaView: View {
    let store: NowPlayingStore
    let lyrics: LyricsStore
    let modes: PlayerModesStore
    let settings: IslandSettings
    /// Clicking the artwork opens the full-screen player (PRD F6).
    var openFullScreen: () -> Void = {}

    private var showsLyrics: Bool { settings.lyricsEnabled && settings.lyricsModeOn }
    /// The output list shows in place of the player (C1), like the iPhone's Control Center page.
    @State private var showingOutputs = false
    /// The swipe on the controls, while your fingers move and as it lands (SidePaging).
    @State private var paging = SidePager()
    @Environment(AudioOutputsStore.self) private var outputs: AudioOutputsStore?
    @Environment(TipsStore.self) private var tips: TipsStore?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if showingOutputs, let outputs {
                OutputList(store: outputs) { showingOutputs = false }
                    .padding(16)
                    .transition(.opacity)
            } else {
                player.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showingOutputs)
        .animation(.easeInOut(duration: 0.2), value: lyrics.syncing)
        // The island closing, or lyrics turned off, finishes the timing fix (each step is already saved).
        .onDisappear { lyrics.endSync(in: .island) }
        .onChange(of: showsLyrics) { _, shown in if !shown { lyrics.endSync(in: .island) } }
    }

    private var player: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    tips?.learned(.cover)  // you found it yourself: that tip never shows
                    openFullScreen()
                } label: {
                    ExpandingArtwork(image: store.artwork)
                }
                .buttonStyle(.plain)
                .help("Full-screen player")
                .accessibilityLabel("Open the full-screen player")
                // Only the quote button switches title ↔ lyrics. A lyric line jumps to itself when clicked,
                // like the full-screen player (the whole area used to switch modes: your P-3 test found it).
                textArea
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    if settings.lyricsEnabled {
                        LyricsButton(isOn: settings.lyricsModeOn) {
                            settings.lyricsModeOn.toggle()
                            Usage.note(settings.lyricsModeOn ? "lyrics.mode.on" : "lyrics.mode.off")
                        }
                    }
                    if let icon = store.sourceIcon {
                        // Click → the app comes forward (your request; both checks passed 2026-09-30).
                        // 24 pt frame: the icon's own artwork fills about 20 pt of it, level with the 26 pt button.
                        Button(action: store.openSourceApp) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(store.sourceName.map { "Open \($0)" } ?? "Open the app")
                        .accessibilityLabel(store.sourceName.map { "Open \($0)" } ?? "Open the app")
                    }
                }
            }

            if let item = store.item {
                ProgressRow(item: item, onSeek: store.seek(to:))
            }

            if lyrics.syncing == .island, showsLyrics {
                // Fixing the lyrics' timing: the bar takes the controls' place for a moment (the island keeps its size).
                LyricsSyncBar(lyrics: lyrics)
                    .transition(.opacity)
            } else {
            TransportRow(store: store, modes: modes, sideButtons: settings.sideButtons, pagePosition: paging.position,
                         onOutput: { showingOutputs = true })
                .onSidewaysPaging(changed: { paging.follow($0, on: settings.sideButtons) },
                                  ended: { dx, speed in
                                      paging.land(dx, speed: speed, settings: settings, reduceMotion: reduceMotion) {
                                          Usage.note("sides.swipe")
                                          tips?.learned(.swipe)
                                      }
                                  })
                .overlay(alignment: .bottom) {
                    // In the bottom padding, under the row: which pair shows, and a click to switch (the click path
                    // every gesture needs, docs/05-interaction-model.md).
                    SidePageDots(selected: settings.sideButtons, position: paging.position) { switchSides(to: $0) }
                        .offset(y: 14)
                }
            }
        }
        .padding(16)
    }

    /// The other pair of buttons beside the controls (your pick, 2026-10-05). It's the setting in Settings → Media &
    /// Lyrics → "Buttons beside the controls", so the pair you leave it on stays; the full-screen player shows it too.
    private func switchSides(to buttons: SideButtons) {
        guard buttons != settings.sideButtons else { return }
        Usage.note("sides.dot")
        paging.reset()
        withAnimation(SideButtonsSwitch.animation(reduceMotion: reduceMotion)) { settings.sideButtons = buttons }
    }
}

/// How the pair beside the controls changes: shared with the debug capture, so the pictures show the real motion.
public enum SideButtonsSwitch {
    public static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.28)
    }

    /// After your fingers lift: a spring from where they left the pages, settling without a wobble.
    static func landing(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.34, dampingFraction: 0.88)
    }
}

/// The swipe on the controls row (your pick, 2026-11-16: it follows your fingers): where the pages are while they
/// move, then the landing. Used by the open island and the full-screen player.
@MainActor @Observable
final class SidePager {
    /// Nil when nothing is moving: the row sits on its page.
    private(set) var position: Double?
    /// Each swipe's turn: a landing that finishes after a new swipe began leaves the new one alone.
    @ObservationIgnored private var turn = 0

    func follow(_ fingerDX: Double, on buttons: SideButtons) {
        turn += 1
        position = SidePaging.position(page: buttons.page, fingerDX: fingerDX)
    }

    /// Past halfway or a flick: the other pair, with a tick; otherwise it springs back. The page changes first, with
    /// the row still where your fingers left it; then a spring carries it the rest of the way, so nothing jumps.
    func land(_ fingerDX: Double, speed: Double, settings: IslandSettings, reduceMotion: Bool, switched: () -> Void) {
        let page = settings.sideButtons.page
        let at = SidePaging.position(page: page, fingerDX: fingerDX)
        let target = SidePaging.landing(page: page, position: at, velocity: speed)
        turn += 1
        let mine = turn
        position = at
        if target != page {
            settings.sideButtons = target == 0 ? .shuffleRepeat : .favoriteOutput
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            switched()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.turn == mine else { return }
            withAnimation(SideButtonsSwitch.landing(reduceMotion: reduceMotion)) {
                self.position = Double(target)
            } completion: { [weak self] in
                guard let self, self.turn == mine else { return }
                self.position = nil
            }
        }
    }

    /// A dot was clicked: the row goes by the setting again.
    func reset() {
        turn += 1
        position = nil
    }
}

extension SideButtons {
    /// Its page: Shuffle & Repeat on the left (0), Favorite & Output on the right (1).
    var page: Int { self == .shuffleRepeat ? 0 : 1 }
}

/// Two dots under the controls: which pair of side buttons shows (left: Shuffle & Repeat, right: Favorite & Output).
/// The one you're on is stretched into a short bar, like the site's carousel (your pick, 2026-11-16); as your fingers
/// swipe, it shrinks back to a dot while the other one stretches, following them. Clicking one switches to its pair.
struct SidePageDots: View {
    let selected: SideButtons
    /// Where the pages are while you swipe (SidePaging); nil: on `selected`.
    var position: Double?
    let onSelect: (SideButtons) -> Void

    var body: some View {
        let at = position ?? Double(selected.page)
        HStack(spacing: 0) {
            ForEach(SideButtons.allCases, id: \.self) { buttons in
                let shown = SidePaging.visibility(of: buttons.page, at: at)
                Button { onSelect(buttons) } label: {
                    Capsule()
                        .fill(Color.primary.opacity(0.3 + 0.55 * shown))
                        .frame(width: 5 + 7 * shown, height: 5)
                        .frame(width: 20, height: 14)  // a target bigger than the dot
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(buttons.title)
                .accessibilityLabel(buttons.title)
                .accessibilityAddTraits(buttons == selected ? .isSelected : [])
            }
        }
    }
}

extension ExpandedMediaView {
    @ViewBuilder
    private var textArea: some View {
        if showsLyrics {
            LyricsArea(lyrics: lyrics, song: [store.item?.title, store.item?.artist].compactMap { $0 }.joined(separator: " · "),
                       sweep: settings.lyricsSweep, onSeek: { time in
                           // While fixing the timing, a click on a line lines the lyrics up with it instead of jumping.
                           if lyrics.syncing == .island { lyrics.syncLine(shownAt: time) } else { store.seek(to: time) }
                       })
        } else {
            // Each line loops while the island is open, if it doesn't fit (your pick, 2026-10-29: everywhere).
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(trigger: store.item?.identity, gap: 48) {
                    Text(store.item?.title ?? "")
                        .font(.system(size: 14, weight: .semibold))
                }
                MarqueeText(trigger: store.item?.identity, gap: 42) {
                    Text(store.item?.artist ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A plain symbol button with a comfortable hit area (≥ 28 pt, PRD §8.3).
struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let label: String
    /// Set while the button can't work (the player isn't answering Brim): it fades and says why on hover.
    var unavailableReason: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(unavailableReason == nil ? Color.primary : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 30)
                    .contentShape(Rectangle())
                if unavailableReason != nil {
                    UnavailableBadge()
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(unavailableReason != nil)
        .overlay {
            // A disabled button may not show its own tooltip (see ModeButton).
            if let unavailableReason { Color.clear.contentShape(Rectangle()).help(unavailableReason) }
        }
        .accessibilityLabel(label)
        .accessibilityHint(unavailableReason ?? "")
    }
}

/// A small, neutral cue that a control is intentionally unavailable. The hover hint carries the full explanation;
/// this badge keeps the state legible without adding another persistent label to the compact island.
struct UnavailableBadge: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(2)
            .background(.regularMaterial, in: Circle())
            .offset(x: 3, y: 3)
            .accessibilityHidden(true)
    }
}

/// The open island's artwork, which opens the full-screen player: on hover it says so, like Apple Music's mini player
/// (your video, 2026-10-29): it grows a little, dims, and diagonal arrows appear in the middle.
struct ExpandingArtwork: View {
    let image: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        ArtworkView(image: image, size: 56, cornerRadius: 10)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(hovering ? 0.4 : 0))
                Image(systemName: "arrow.down.left.and.arrow.up.right")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .opacity(hovering ? 1 : 0)
                    .scaleEffect(hovering || reduceMotion ? 1 : 0.85)
            }
            .scaleEffect(hovering && !reduceMotion ? 1.07 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: hovering)
            // The whole square, edges included, and a few points around it (your report: only the middle reacted).
            .padding(4)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active = phase { hovering = true } else { hovering = false }
            }
            .padding(-4)
    }
}

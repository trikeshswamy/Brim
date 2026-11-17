import SwiftUI
import BrimCore

/// Previous · play/pause · next, or −15 · play/pause · +15 for videos, podcasts, and long items (PRD F2),
/// with shuffle and repeat at the sides when the player is Spotify or Music, or ★ and the output (your setting).
/// Used by the open island and (large) by the full-screen player.
struct TransportRow: View {
    let store: NowPlayingStore
    let modes: PlayerModesStore
    var large = false
    /// Settings → Media: Shuffle & Repeat, or Favorite & Output (C1).
    var sideButtons: SideButtons = .shuffleRepeat
    /// Where the pages are while your fingers swipe (SidePaging: 0 Shuffle & Repeat … 1 Favorite & Output); nil: on
    /// `sideButtons`' page.
    var pagePosition: Double?
    /// In the island the output list opens in place; without this (full screen) it opens as a popover.
    var onOutput: (() -> Void)?
    /// Room between the buttons when there are side buttons; nil: the usual. The full-screen player spreads them on a
    /// big screen (FullScreenLayout.controlSpacing).
    var spacing: CGFloat?
    @Environment(AudioOutputsStore.self) private var outputs: AudioOutputsStore?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingOutputs = false

    var body: some View {
        let skip = store.item?.prefersSkipButtons == true
        // Brim talks straight to Spotify or Music while macOS's Now Playing app is another (paused) one; a command there
        // that didn't go through fades ⏮ ⏯ ⏭ with the reason for a moment (your report, 2026-10-02).
        let direct: Bool = if case .player = store.source { true } else { false }
        let blocked = direct && store.directControlFailed ? SideSlot.unreachableReason(player: modes.player) : nil
        let seekBlocked = store.item?.supportsSeeking == false ? "Safari did not expose a seek control for this video." : nil
        let slots = slots(for: sideButtons, skip: skip)
        let hasSides = slots.left != nil || slots.right != nil
        let extra = (spacing ?? 40) - 40  // how much wider than usual, also without side buttons
        return HStack(spacing: hasSides ? (large ? 40 + extra : 24) : (large ? 56 + extra : 40)) {
            if hasSides { pagedSlot(left: true, skip: skip) }
            ControlButton(symbol: skip ? "gobackward.15" : "backward.fill", size: large ? 26 : 16,
                          label: skip ? "Back 15 seconds" : "Previous track", unavailableReason: skip ? (seekBlocked ?? blocked) : blocked,
                          action: skip ? store.skipBackward : store.previousTrack)
            ControlButton(symbol: store.isPlaying ? "pause.fill" : "play.fill", size: large ? 38 : 22,
                          label: store.isPlaying ? "Pause" : "Play", unavailableReason: blocked,
                          action: store.togglePlayPause)
            ControlButton(symbol: skip ? "goforward.15" : "forward.fill", size: large ? 26 : 16,
                          label: skip ? "Forward 15 seconds" : "Next track", unavailableReason: skip ? (seekBlocked ?? blocked) : blocked,
                          action: skip ? store.skipForward : store.nextTrack)
            if hasSides { pagedSlot(left: false, skip: skip) }
        }
        // Read shuffle/repeat/★ when the buttons appear and when the song changes; never on a timer.
        .onAppear { modes.refresh() }
        .onChange(of: store.item?.identity) { modes.refresh() }
    }

    private func slots(for pair: SideButtons, skip: Bool) -> (left: SideSlot?, right: SideSlot?) {
        var slots = SideSlot.slots(buttons: pair, modes: modes.modes, player: modes.player, skipButtons: skip,
                                   unreachable: modes.unreachable)
        if slots.right == .output, outputs == nil { slots.right = nil }  // previews and tests have no outputs
        return (slots.left, slots.right)
    }

    /// One place beside the controls, with both pairs' buttons in it, each drawn where the pages are: on its page it
    /// sits still; as your fingers swipe, it slides with them and fades, while the other pair's slides in from the
    /// side (your pick, 2026-11-16: it follows your fingers, like a carousel). Shuffle & Repeat's page is to the left,
    /// Favorite & Output's to the right, like their dots. Only the pair you're on takes clicks. Reduce Motion: a fade.
    private func pagedSlot(left: Bool, skip: Bool) -> some View {
        let position = pagePosition ?? Double(sideButtons.page)
        let slide: Double = reduceMotion ? 0 : (large ? 34 : 24)
        return ZStack {
            ForEach(SideButtons.allCases, id: \.self) { pair in
                let shown = SidePaging.visibility(of: pair.page, at: position)
                let pairSlots = slots(for: pair, skip: skip)
                // Faster than linear and a little smaller on the way out, so halfway through the two never sit
                // half-faded on top of each other.
                side(left ? pairSlots.left : pairSlots.right)
                    .scaleEffect(reduceMotion ? 1 : 0.82 + 0.18 * shown)
                    .offset(x: (Double(pair.page) - position) * slide)
                    .opacity(shown * shown * (3 - 2 * shown))
                    .allowsHitTesting(shown > 0.5)
                    .accessibilityHidden(shown <= 0.5)
            }
        }
    }

    @ViewBuilder
    private func side(_ slot: SideSlot?) -> some View {
        let sides = modes.modes
        // Shown faded when the player didn't answer (no modes): the reason comes up on hover.
        let canChange = sides != nil && sides?.canChange != false
        let unreachable = sides?.changeableOnlyInFront == true ? SideSlot.spotifyOnlyInFrontReason
            : modes.unreachable ? SideSlot.unreachableReason(player: modes.player) : nil
        switch slot {
        case .shuffle?:
            ModeButton(symbol: "shuffle", isOn: sides?.shuffle == true, enabled: canChange, large: large,
                       label: "Shuffle", unavailableReason: unreachable, action: modes.toggleShuffle)
        case .repeat?:
            ModeButton(symbol: sides?.repeatMode == .one ? "repeat.1" : "repeat", isOn: (sides?.repeatMode ?? .off) != .off,
                       enabled: canChange, large: large,
                       label: sides?.repeatMode == .one ? "Repeat one" : "Repeat",
                       hint: modes.player == .spotify && sides?.repeatHasOne != true ? Self.spotifyRepeatHint : nil,
                       unavailableReason: unreachable, action: modes.cycleRepeat)
        case .favorite?:
            // A star, like Apple Music's own Favorite. Dimmed where it can't work, and the hover says why.
            ModeButton(symbol: sides?.favorite == true ? "star.fill" : "star", isOn: sides?.favorite == true,
                       enabled: SideSlot.canFavorite(modes: sides, player: modes.player), large: large,
                       label: sides?.favorite == true ? "Favorited" : "Favorite",
                       unavailableReason: SideSlot.favoriteUnavailableReason(player: modes.player, unreachable: modes.unreachable,
                                                                             needsReconnect: sides?.favoriteNeedsReconnect == true),
                       action: modes.toggleFavorite)
        case .output?:
            OutputButton(output: outputs?.current, large: large) {
                if let onOutput { onOutput() } else { showingOutputs = true }
            }
            .popover(isPresented: $showingOutputs, arrowEdge: .bottom) {
                if let outputs {
                    OutputList(store: outputs) { showingOutputs = false }
                        .frame(width: 280, height: min(CGFloat(outputs.outputs.count) * 34 + 40, 260))
                        .padding(10)
                }
            }
        case nil:
            // Keeps the play controls centred when only one side has a button.
            Color.clear.frame(width: large ? 40 : 28, height: large ? 34 : 26)
        }
    }

    /// Spotify's scripting has only repeat on/off, and it ignores macOS's repeat command (checked 2026-09-29,
    /// Spotify 1.3.0), so Brim can't pick Repeat One there. Said on hover instead of a button that silently skips it.
    static let spotifyRepeatHint = "Repeat on or off. Repeat One needs Spotify Premium, connected in Settings → Media & Lyrics."
}

/// The output button: the current output's own icon (AirPods, speakers…), like the iPhone.
struct OutputButton: View {
    let output: AudioOutput?
    var large = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: output?.symbolName ?? "airplayaudio")
                .font(.system(size: large ? 18 : 13, weight: .semibold))
                .frame(width: large ? 40 : 28, height: large ? 34 : 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(output.map { "Playing on \($0.name)" } ?? "Choose the output")
        .accessibilityLabel("Output")
        .accessibilityValue(output?.name ?? "")
    }
}

/// Shuffle, repeat or ★: bright on a soft disc when on, dim when off, faded when it can't be used.
struct ModeButton: View {
    let symbol: String
    let isOn: Bool
    let enabled: Bool
    var large = false
    let label: String
    /// Hover text when it says more than the label (Spotify's two-state repeat).
    var hint: String?
    /// Hover text while it's dimmed, when there's a specific reason (★ with Spotify).
    var unavailableReason: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: symbol)
                    .font(.system(size: large ? 18 : 13, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: large ? 40 : 28, height: large ? 34 : 26)
                    .background(isOn ? Color.primary.opacity(0.15) : .clear,
                                in: RoundedRectangle(cornerRadius: large ? 9 : 7, style: .continuous))
                    .contentShape(Rectangle())
                if !enabled {
                    UnavailableBadge()
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(tooltip)
        .overlay {
            // Also on a clear layer above a faded button: a disabled button may not show its own tooltip.
            if !enabled { Color.clear.contentShape(Rectangle()).help(tooltip) }
        }
        .accessibilityLabel(label)
        .accessibilityHint(enabled ? hint ?? "" : unavailableReason ?? "")
        .accessibilityValue(isOn ? "On" : "Off")
    }

    private var tooltip: String {
        enabled ? hint ?? label : unavailableReason ?? "\(label) isn't available for what's playing"
    }

    private var iconColor: Color {
        guard enabled else { return .secondary }
        return isOn ? .primary : .primary.opacity(0.45)
    }
}

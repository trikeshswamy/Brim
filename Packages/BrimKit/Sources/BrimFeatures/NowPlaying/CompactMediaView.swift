import SwiftUI
import BrimCore

/// The pill as a song starts: art · title · artist · moving bars in the art's colour, for 3 s (the "peek",
/// your pick 2026-09-30), then it shrinks back to `KeptMusicView`.
struct CompactMediaView: View {
    let store: NowPlayingStore

    var body: some View {
        HStack(spacing: 9) {
            ArtworkView(image: store.artwork, size: 20, cornerRadius: 5)
            if let item = store.item {
                // Title and artist glide together, once per song (not again after every volume change).
                MarqueeText(trigger: item.identity, onceKey: "pill|\(item.title)|\(item.artist ?? "")|\(item.album ?? "")") {
                    HStack(spacing: 9) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold))
                        if let artist = item.artist {
                            Text(artist)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .layoutPriority(1)
            }
            Spacer(minLength: 4)
            WaveformView(isPlaying: store.isPlaying, tint: store.artworkTint)
        }
        .padding(.horizontal, 11)
        .accessibilityElement(children: .combine)
    }
}

/// The kept pill: artwork and moving bars only (your picks, 2026-09-30). Hover or click to open the island.
/// When the song changes while music plays, the artwork turns to the new cover; the pill doesn't widen (decision 12).
struct KeptMusicView: View {
    let store: NowPlayingStore
    let appearance: IslandAppearance
    /// Nil: `IslandMetrics.pillArtSize` (20 pt in Glass, 19 in Black). Set only by the debug side-by-side.
    var artSize: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let art = artSize ?? IslandMetrics.pillArtSize(appearance: appearance)
        HStack(spacing: 0) {
            // One cover at a time, keyed by each real change, so the old one can turn away as the new one turns in.
            ZStack {
                ArtworkView(image: store.artwork, size: art, cornerRadius: 5)
                    .id(store.artworkVersion)
                    .transition(reduceMotion ? .opacity.animation(.easeInOut(duration: 0.25)) : ArtworkFlip.transition)
            }
            .frame(width: art, height: art)
            Spacer(minLength: 6)
            WaveformView(isPlaying: store.isPlaying, tint: store.artworkTint)
        }
        // How far in from the pill's ends, the same on both sides (your screenshot, 2026-09-30: the art sat too close to
        // the edge). Glass was 5 pt, which put the art's corners 2.1 pt from the round end; at 9 pt they clear it by
        // 4.4 pt, about the 5 pt above and below. Black, at 8 pt, already clears its curve by 4.3 pt.
        .padding(.horizontal, appearance == .black ? 8 : 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(store.item.map { "Now playing: \($0.title)" } ?? "Now playing")
    }
}

/// The pill's cover turning to the next song's, like a card (decision 12, after the iPhone's Dynamic Island): the old
/// one turns away (0.18 s), then the new one turns in (0.2 s), around the vertical axis. At rest both turns are 0°,
/// so the two transitions never add up (unlike the 0.13.3 bubbles' offsets).
enum ArtworkFlip {
    static var transition: AnyTransition {
        .asymmetric(
            insertion: AnyTransition.modifier(active: Turn(angle: -90), identity: Turn(angle: 0))
                .animation(.easeOut(duration: 0.2).delay(0.18)),
            removal: AnyTransition.modifier(active: Turn(angle: 90), identity: Turn(angle: 0))
                .animation(.easeIn(duration: 0.18)))
    }

    struct Turn: ViewModifier {
        let angle: Double

        func body(content: Content) -> some View {
            content
                .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                .opacity(abs(angle) >= 90 ? 0 : 1)
        }
    }
}

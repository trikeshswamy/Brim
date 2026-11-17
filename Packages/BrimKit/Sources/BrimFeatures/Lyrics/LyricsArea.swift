import SwiftUI
import BrimCore

/// What the open island's lyrics area shows (layout A, your pick 2026-09-29). Pure, so it's unit-tested.
struct LyricsDisplay: Equatable {
    enum Style: Equatable {
        /// A lyric line: bright current line, dim next line.
        case line
        /// A message about the lyrics (loading, not found…) with the song underneath.
        case status
    }

    var primary: String
    var secondary: String?
    var style: Style
    /// Where each shown line starts, so a click can jump there (nil for messages and the intro note).
    var primaryTime: TimeInterval?
    var secondaryTime: TimeInterval?

    /// `song` is "Title · Artist", shown under status messages so you still know what's playing.
    static func make(status: LyricsStore.Status, lyrics: Lyrics?, currentIndex: Int?, song: String) -> LyricsDisplay {
        func message(_ text: String) -> LyricsDisplay { LyricsDisplay(primary: text, secondary: song, style: .status) }
        switch status {
        case .ready:
            switch lyrics {
            case .synced(let lines)?:
                // Before the first line, or in an instrumental gap: a note instead of an empty line.
                let current = currentIndex.map { lines[$0] }
                let start = (currentIndex ?? -1) + 1
                let next = start < lines.count ? lines[start...].first { !$0.text.isEmpty } : nil
                let hasWords = current?.text.isEmpty == false
                return LyricsDisplay(primary: hasWords ? current!.text : "♪", secondary: next?.text, style: .line,
                                     primaryTime: hasWords ? current?.time : nil, secondaryTime: next?.time)
            case .plain?: return message("Lyrics without timing")
            case .instrumental?: return message("♪ Instrumental")
            case nil: return message("Finding lyrics…")
            }
        // Light, and still saying what's going on (your pick, 2026-09-30).
        case .loading: return message("Finding lyrics…")
        case .notFound: return message("Oops, you caught us. No lyrics for this one yet.")
        case .offline: return message("Lyrics are offline. Back when you are.")
        case .rateLimited: return message("Catching our breath. Lyrics in a moment.")
        case .failed: return message("I can't find them. They're here somewhere!")
        case .none: return message("No lyrics here. Just vibes.")
        case .off: return message("Lyrics are off")
        }
    }
}

/// The lyrics in place of the title and artist. Each new line slides up (Reduce Motion: fades).
/// Click a line to jump there, like the full-screen player (your P-3 feedback): the current line restarts,
/// the next line plays from its start. Only the quote button switches back to the title.
/// While this is on screen, the lyrics store keeps the current line in time; when it goes, the tracking stops.
struct LyricsArea: View {
    let lyrics: LyricsStore
    let song: String
    /// Letters light up as they're sung (Settings → Media & Lyrics); off: the whole line is lit.
    var sweep = false
    let onSeek: (TimeInterval) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let display = LyricsDisplay.make(status: lyrics.status, lyrics: lyrics.lyrics,
                                         currentIndex: lyrics.currentIndex, song: song)
        ZStack(alignment: .leading) {
            content(display)
                .id(lyrics.currentIndex ?? -1)
                .transition(reduceMotion
                            ? .opacity
                            : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                          removal: .move(edge: .top).combined(with: .opacity)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .animation(.easeInOut(duration: 0.3), value: lyrics.currentIndex)
        .onAppear { lyrics.beginDisplay() }
        .onDisappear { lyrics.endDisplay() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(display.style == .line ? "Lyrics: \(display.primary)" : display.primary)
    }

    @ViewBuilder
    private func content(_ display: LyricsDisplay) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch display.style {
            case .line:
                // The "♪" of an intro or gap has no words to sweep (and no time to jump to).
                LyricLines(current: display.primary, next: display.secondary, currentTime: display.primaryTime,
                           nextTime: display.secondaryTime,
                           clock: sweep && display.primaryTime != nil ? lyrics.sweepClock : nil, onSeek: onSeek)
            case .status:
                // Two lines, so a longer message ("I can't find them. They're here somewhere!") is read in full
                // instead of cut (your fix, 2026-09-30). The song line stays under it; the island doesn't grow.
                Text(display.primary)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let song = display.secondary {
                    Text(song)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// The current line (bright, sweeping) and the next one (dim). A line too long for two lines takes the next line's
/// place: up to three lines, same size (your screenshot, 2026-10-01: long lines ended in "…"). The next line comes
/// back with the next lyric, and the island never grows: three lines (57 pt) take the room of two and the next (58).
struct LyricLines: View {
    let current: String
    let next: String?
    var currentTime: TimeInterval?
    var nextTime: TimeInterval?
    var clock: SweepClock?
    var onSeek: (TimeInterval) -> Void = { _ in }

    /// What the choice is measured against (measured 2026-10-01): two lines and the next (58 pt) or three lines alone
    /// (57) fit; three lines and the next (77) or four alone (76) don't.
    static let room: CGFloat = 66

    var body: some View {
        // ViewThatFits builds only the layout it shows (checked: the other one's sweep never starts).
        ProposedHeight(room: Self.room) {
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: 4) {
                    currentLine(lineLimit: nil)
                    if let next {
                        Text(next)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.38))
                            .lineLimit(1)
                            .jumps(to: nextTime, onSeek)
                    }
                }
                currentLine(lineLimit: 3)
            }
        }
    }

    private func currentLine(lineLimit: Int?) -> some View {
        SweepLine(text: current, size: 15, weight: .bold, lineLimit: lineLimit, dim: 0.5, clock: clock)
            .jumps(to: currentTime, onSeek)
    }
}

/// Measures its content against a height of `room` but takes only the height the content uses, so ViewThatFits can
/// choose without the open island growing to `room`.
private struct ProposedHeight: Layout {
    let room: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: room)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: room))
    }
}

private extension View {
    /// Makes a lyric line a click target that jumps to `time` (nothing to click when there's no time).
    @ViewBuilder
    func jumps(to time: TimeInterval?, _ onSeek: @escaping (TimeInterval) -> Void) -> some View {
        if let time {
            contentShape(Rectangle())
                .onTapGesture { onSeek(time) }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Plays from this line")
        } else {
            self
        }
    }
}

/// The quote-bubble button next to the app icon: lyrics on (filled, bright) or off.
/// 28 × 26 pt (a little bigger after your P-3 test), still well clear of the lyric lines.
struct LyricsButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "quote.bubble.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isOn ? Color.black : Color.primary.opacity(0.7))
                .frame(width: 28, height: 26)
                .background(isOn ? Color.white : Color.primary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Show the title" : "Show lyrics")
        .accessibilityLabel("Lyrics")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

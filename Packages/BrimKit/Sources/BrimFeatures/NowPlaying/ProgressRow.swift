import SwiftUI
import BrimCore

/// Elapsed · bar · remaining. The two times redraw once a second, only while playing and only while on screen;
/// the bar is set once per change and moved by Core Animation (see `ProgressBar`).
/// The position is computed from the last event (`NowPlaying.position(at:)`), never asked for again.
struct ProgressRow: View {
    let item: NowPlaying
    /// The full-screen player's bigger version.
    var large = false
    /// Drag the bar to jump (PRD F2 "Seek"). Nil, or a song without a length: the bar can't be dragged.
    var onSeek: ((TimeInterval) -> Void)?

    /// While dragging (and for a moment after letting go), where the finger is, 0 … 1.
    @State private var dragFraction: Double?

    var body: some View {
        let duration = item.duration ?? 0
        let position = item.position(at: .now) ?? 0
        let rate = max(item.playbackRate ?? 1, 0.1)
        let seekable = onSeek != nil && duration > 0 && item.supportsSeeking != false
        HStack(spacing: large ? 10 : 8) {
            timeSlot(fitting: TimeFormat.clock(duration), atLeast: large ? 48 : 38, alignment: .leading) {
                TimelineView(PlaybackSchedule(isPlaying: item.isPlaying && dragFraction == nil)) { context in
                    Text(TimeFormat.clock(dragFraction.map { $0 * duration } ?? item.position(at: context.date) ?? 0))
                }
            }
            ProgressBar(fraction: dragFraction ?? (duration > 0 ? position / duration : 0),
                        secondsToEnd: dragFraction == nil && item.isPlaying && duration > 0 ? max(0, duration - position) / rate : nil,
                        height: large ? 6 : 4)
                .overlay {
                    if seekable {
                        // A taller, invisible grab area: the bar itself is only 4–6 pt.
                        GeometryReader { proxy in
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0)
                                    .onChanged { drag in
                                        dragFraction = min(max(drag.location.x / max(proxy.size.width, 1), 0), 1)
                                    }
                                    .onEnded { _ in
                                        guard let dragFraction else { return }
                                        onSeek?(dragFraction * duration)
                                        releaseDrag()
                                    })
                        }
                        .frame(height: 20)
                    }
                }
            timeSlot(fitting: TimeFormat.remaining(duration), atLeast: large ? 54 : 42, alignment: .trailing) {
                TimelineView(PlaybackSchedule(isPlaying: item.isPlaying && dragFraction == nil)) { context in
                    let at = dragFraction.map { $0 * duration } ?? item.position(at: context.date) ?? 0
                    Text(TimeFormat.remaining(max(0, duration - at)))
                }
            }
        }
        .font(.system(size: large ? 13 : 11).monospacedDigit())
        .foregroundStyle(.secondary)
        // The helper confirms the jump with a new position; until then keep showing where you let go.
        .onChange(of: item.timestamp) { dragFraction = nil }
        // A real slider for VoiceOver (the VoiceOver pass, 2026-11-17): "Playback position, 1:20 of 3:45", and
        // VO-arrows jump 15 s when the song can be moved.
        .accessibilityRepresentation {
            Slider(value: Binding(get: { position }, set: { next in
                guard seekable else { return }
                onSeek?(min(max(position + (next > position ? 15 : -15), 0), duration))
            }), in: 0...max(duration, 1)) {
                Text("Playback position")
            }
            .accessibilityValue(duration > 0 ? "\(TimeFormat.clock(position)) of \(TimeFormat.clock(duration))"
                                             : TimeFormat.clock(position))
            .disabled(!seekable)
        }
    }

    /// A time label as wide as the longest time this item can show (`widest`: the duration itself, digits are all the
    /// same width), never narrower than `atLeast`, and on one line. Your screenshot, 2026-09-30: a fixed width made for
    /// "3:45" wrapped "−1:45:14" onto two lines. Songs keep exactly the widths they had.
    private func timeSlot(fitting widest: String, atLeast: CGFloat, alignment: Alignment,
                          @ViewBuilder _ label: () -> some View) -> some View {
        Text(widest)
            .hidden()
            .frame(minWidth: atLeast, alignment: alignment)
            .overlay(alignment: alignment) { label() }
            .lineLimit(1)
            .fixedSize()
    }

    /// Keep the released position on screen until the player confirms, at most 1.5 s.
    private func releaseDrag() {
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            dragFraction = nil
        }
    }
}

/// A `TimelineSchedule` that ticks every second while playing and only once while paused.
/// This is how "no timers while nothing changes" looks in SwiftUI.
struct PlaybackSchedule: TimelineSchedule {
    let isPlaying: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        guard isPlaying else { return AnyIterator([startDate].makeIterator()) }
        var next = startDate
        return AnyIterator {
            defer { next = next.addingTimeInterval(1) }
            return next
        }
    }
}

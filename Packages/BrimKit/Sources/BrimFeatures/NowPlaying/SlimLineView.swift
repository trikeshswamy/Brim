import SwiftUI
import BrimCore

/// The slim line (Settings → Island → Show it as → Slim line): the kept music indicator as a thin line that covers
/// none of an app's toolbar. The art's colour while playing, grey while paused.
///
/// Live Activities ride on it as marks (your pick A, 2026-09-30): a dot on the left while keep-awake is on, and on the
/// right a small bar that drains as the next countdown (a timer, a class in its last 10 minutes) runs down. With no
/// music, only the marks show. For the details and every timer, open the island as usual.
struct SlimLineView: View {
    let appearance: IslandAppearance
    let tint: TintColor?
    let isPlaying: Bool
    /// The music line (off when nothing is kept and only Live Activities rest).
    var showsLine = true
    var marks: SideBubbles = .none
    var timer: TimerStore?
    var calendar: CalendarStore?
    var geometry: IslandDisplayGeometry = .reference
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let w = IslandMetrics.slimPartWidths(appearance: appearance, geometry: geometry)
        let height: CGFloat = appearance == .black ? 2.5 : 4
        HStack(spacing: w.gap) {
            if marks.left {
                Circle().fill(Color.orange).frame(width: w.dot, height: w.dot)
                    .accessibilityLabel("Keeping your Mac awake")
            }
            if showsLine {
                Capsule().fill(color).frame(width: w.line, height: height)
                    .animation(.easeInOut(duration: 0.3), value: isPlaying)
                    // A new song fades the line to its colour (decision 12: the full pill no longer shows for it).
                    .animation(.easeInOut(duration: 0.4), value: tint)
                    .accessibilityLabel(isPlaying ? "Music playing" : "Music paused")
            }
            if let countdown = marks.right {
                // Redraws every 5 s, only while it shows.
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    let share = IslandSides.share(of: countdown, timer: timer, calendar: calendar, at: context.date)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.orange.opacity(0.3))
                        Capsule().fill(Color.orange).frame(width: w.bar * share)
                    }
                    .frame(width: w.bar, height: height)
                }
                .accessibilityLabel("Countdown running")
            }
        }
    }

    private var color: Color {
        let onDark = appearance.isSolidBlack || colorScheme == .dark
        guard isPlaying else { return onDark ? .white.opacity(0.45) : .black.opacity(0.35) }
        return Color(nsColor: ArtColor.resolve(tint, onDark: onDark))
    }
}

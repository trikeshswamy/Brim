import SwiftUI
import BrimCore

/// The Calendar tab (decision 7, 2026-09-30): the time and date with the gear, then today's agenda: ended events
/// dimmed, the current one "now · until 17:00", the rest counting down, Join where there's a meeting link.
/// Three rows show; more scroll, starting at the next event.
struct CalendarTabView: View {
    let actions: IslandActions
    var calendar: CalendarStore?
    /// Settings → Calendar → Show your next event.
    var showsEvent = false
    @Environment(\.offscreenRender) private var offscreenRender

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                // Redraws once a minute, only while this tab is on screen. Your menu bar is hidden, so the clock
                // lives here.
                TimelineView(.everyMinute) { context in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(context.date, format: .dateTime.hour().minute())
                            .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        Text(context.date, format: .dateTime.weekday(.wide).day().month(.wide))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(action: actions.openSettings) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            .frame(height: 26)
            if showsEvent, let calendar, !calendar.agenda.isEmpty {
                agenda(calendar)
            } else {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(height: 32)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func agenda(_ calendar: CalendarStore) -> some View {
        let rows = VStack(spacing: 6) {
            ForEach(calendar.agenda) { event in
                AgendaRow(event: event).id(event.id)
            }
        }
        if calendar.agenda.count > 3 && !offscreenRender {
            ScrollViewReader { reader in
                ScrollView(.vertical, showsIndicators: false) { rows }
                    .frame(height: 3 * 32 + 2 * 6)
                    .onAppear {
                        // Start at the next event, not at this morning's.
                        if let next = calendar.agenda.first(where: { $0.end > .now }) { reader.scrollTo(next.id, anchor: .top) }
                    }
            }
        } else {
            rows
        }
    }

    private var message: String {
        guard showsEvent else { return "Calendar is off: Settings → Calendar" }
        switch calendar?.availability {
        // `.starting` = macOS hasn't asked yet (see CalendarStore.message): it needs your OK, so say how.
        case .needsPermission?, .starting?: return "Allow Calendar access in Settings → Calendar"
        case .unavailable?: return "Calendar unavailable"
        default: return "Nothing else today"
        }
    }
}

/// One event: time, the calendar's colour, title, and "ended", "now · until 17:00" or "in 36 min"; Join while it's
/// still to come or running. A click on the event opens it in Apple's Calendar app (your question, 2026-10-05).
private struct AgendaRow: View {
    let event: CalendarEvent
    @Environment(\.openURL) private var openURL

    var body: some View {
        TimelineView(.everyMinute) { context in
            let ended = event.end <= context.date
            HStack(spacing: 9) {
                Button {
                    if let url = event.openURL {
                        Usage.note("calendar.openEvent")
                        openURL(url)
                    }
                } label: {
                    HStack(spacing: 9) {
                        // Wide enough for "12:30 PM" on one line (your Mac uses 12-hour time; 44 pt wrapped "PM").
                        Text(event.start, format: .dateTime.hour().minute())
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(width: 62, alignment: .leading)
                        RoundedRectangle(cornerRadius: 1.5).fill(Color(event.color)).frame(width: 3, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(detail(ended: ended, now: context.date)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(event.openURL == nil)
                .help("Open in Calendar")
                // Join stays its own button, beside the event's.
                if !ended, let url = event.meetingURL {
                    JoinButton(small: true) { openURL(url) }
                }
            }
            .frame(height: 32)
            .opacity(ended ? 0.45 : 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func detail(ended: Bool, now: Date) -> String {
        if ended { return "ended" }
        if event.start <= now { return "now · until \(event.end.formatted(date: .omitted, time: .shortened))" }
        return CalendarRules.countdown(to: event.start, now: now)
    }
}

/// The Music tab with nothing playing.
/// The Now Playing helper keeps stopping (it restarts itself, waiting longer each time, up to a minute): say so, and
/// offer Retry, instead of a quiet "Nothing playing" (PRD F2: helper unavailable → message + Retry).
struct NowPlayingUnavailableView: View {
    let reason: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.orange)
            Text("Brim can't see what's playing")
                .font(.system(size: 13, weight: .semibold))
            Text(reason)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Button("Retry", action: retry)
                .controlSize(.small)
                .padding(.top, 2)
        }
        .padding(.horizontal, 28)
    }
}

struct MusicEmptyView: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "music.note")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Nothing playing")
                .font(.system(size: 13, weight: .semibold))
            Text("Play something in Spotify, Music or your browser.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

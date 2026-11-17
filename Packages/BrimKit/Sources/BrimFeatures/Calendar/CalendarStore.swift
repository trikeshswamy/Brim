import Observation
import SwiftUI
import BrimCore

/// Your next event (F8): in the open island when nothing plays, and a 6 s reminder 5 minutes before it.
/// Event-driven: today's events are re-read only when EventKit, the day, the time zone or waking up says
/// something changed; in between, one sleep until the next moment that matters (a reminder, or the shown
/// event ending).
@Observable
public final class CalendarStore {
    public private(set) var next: CalendarEvent?
    /// The event the reminder is about.
    public private(set) var reminding: CalendarEvent?
    /// A class starting within 10 minutes: its countdown rides beside the pill (decision 8).
    public private(set) var soon: CalendarEvent?
    /// Today's events for the Calendar tab, ended ones included.
    public private(set) var agenda: [CalendarEvent] = []
    /// Your calendars, for Settings → Calendar.
    public private(set) var calendars: [CalendarSource] = []
    public private(set) var availability: Availability = .starting
    /// Settings → Calendar → Show your next event.
    public private(set) var enabled = false
    /// Settings → Calendar → Remind me 5 minutes before.
    @ObservationIgnored public var remindersEnabled = true {
        didSet { if remindersEnabled != oldValue { schedule() } }
    }
    /// Settings → Calendar → the calendars you switched off: their events never show or remind you.
    @ObservationIgnored public var hiddenCalendars: Set<String> = [] {
        didSet { if hiddenCalendars != oldValue { refresh() } }
    }
    /// Each reminder and how late it fired (release goal: within 1 s). The health log keeps these.
    @ObservationIgnored public var onReminder: ((_ lateBy: TimeInterval) -> Void)?

    @ObservationIgnored private let service: any CalendarService
    @ObservationIgnored private let island: IslandCoordinator
    @ObservationIgnored private var events: [CalendarEvent] = []
    @ObservationIgnored private var previewEvents: [CalendarEvent] = []
    @ObservationIgnored private var shown: Set<String> = []
    @ObservationIgnored private var wake: Task<Void, Never>?
    @ObservationIgnored private var listener: Task<Void, Never>?
    /// Tests set the clock by hand.
    @ObservationIgnored var now: () -> Date = Date.init

    public init(service: any CalendarService, island: IslandCoordinator) {
        self.service = service
        self.island = island
    }

    public func start() {
        guard listener == nil else { return }
        let changes = service.changes
        listener = Task { [weak self] in
            for await _ in changes { self?.refresh() }
        }
        service.start()
        refresh()
    }

    /// Turning it on never prompts by itself. Permission is requested from the explicit Grant Access action so a
    /// saved setting cannot make every launch ask again.
    public func setEnabled(_ on: Bool) async {
        enabled = on
        refresh()
    }

    /// Settings → Permissions can request access without silently turning the Calendar feature on.
    public func requestPermission() async {
        _ = await service.requestAccess()
        refresh()
    }

    /// Re-reads today's events and plans the next wake-up.
    public func refresh() {
        availability = service.availability
        let ready = enabled && availability == .ready
        calendars = ready ? service.calendars() : []
        events = CalendarRules.visible(ready ? service.eventsToday() : [], hidden: hiddenCalendars) + previewEvents
        next = enabled ? CalendarRules.next(in: events, now: now()) : nil
        let current = now()
        agenda = enabled ? CalendarRules.agenda(in: events, now: current) : []
        soon = next.flatMap { $0.start > current && $0.start.timeIntervalSince(current) <= SideRules.classWindow ? $0 : nil }
        schedule()
    }

    /// Debug (`--calendar-preview`): a made-up event as if it were in your calendar, starting in 5 min 3 s,
    /// so its reminder shows in 3 s. Nothing is written to your calendar.
    public func preview() {
        let start = now().addingTimeInterval(CalendarRules.reminderLead + 3)
        previewEvents = [CalendarEvent(id: "preview", title: "Design Review · Weekly", start: start,
                                       end: start.addingTimeInterval(3600),
                                       meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"))]
        refresh()
    }

    private func schedule() {
        wake?.cancel()
        guard enabled else { return }
        let current = now()
        let reminder = remindersEnabled ? CalendarRules.nextReminder(in: events, now: current, shown: shown) : nil
        // Wake for the reminder, when the next event's countdown starts (10 min before) and when it starts, or when
        // the shown event ends (the next one takes its place).
        let countdownStart = next.map { $0.start.addingTimeInterval(-SideRules.classWindow) }
        let times = [reminder?.at, next?.end, countdownStart, next?.start].compactMap { $0 }.filter { $0 > current }
        guard let at = times.min() ?? reminder?.at else { return }
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, at.timeIntervalSince(current))), tolerance: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.wakeUp(for: reminder)
        }
    }

    private func wakeUp(for reminder: (event: CalendarEvent, at: Date)?) {
        if let reminder, reminder.at <= now().addingTimeInterval(0.5) {
            remind(about: reminder.event, lateBy: now().timeIntervalSince(reminder.at))
        }
        refresh()
    }

    func remind(about event: CalendarEvent, lateBy: TimeInterval) {
        shown.insert(event.id)
        reminding = event
        island.post(.calendar(at: now()))
        onReminder?(lateBy)
    }
}

extension Color {
    init(_ color: CalendarColor) {
        self.init(red: color.red, green: color.green, blue: color.blue)
    }
}

/// The open island's event row (your pick A, 2026-09-30): the calendar's colour bar, title, time and
/// countdown, and Join when the event has a Zoom, Meet, Teams or FaceTime link.
struct EventRow: View {
    let store: CalendarStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(store.next.map { Color($0.color) } ?? Color.secondary.opacity(0.4))
                .frame(width: 3, height: 30)
            if let event = store.next {
                // The countdown redraws once a minute, and only while the island is open.
                TimelineView(.everyMinute) { context in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text("\(event.start, format: .dateTime.hour().minute()) · \(CalendarRules.countdown(to: event.start, now: context.date))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                if let url = event.meetingURL {
                    JoinButton { openURL(url) }
                }
            } else {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var message: String {
        switch store.availability {
        case .ready: "Nothing else today"
        // `.starting` is EventKit's "not asked yet" (it reads synchronously, so there is no loading): it waits for your
        // OK, not for Brim. Before 0.35.0 it said "Reading your calendar…" forever (your audit, 2026-11-14).
        case .starting, .needsPermission: "Allow Calendar access in Settings → Calendar"
        case .unavailable: "Calendar unavailable"
        }
    }
}

/// Green like FaceTime's join; the one coloured button in the island, because it's the one urgent action.
struct JoinButton: View {
    var small = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if !small { Image(systemName: "video.fill") }
                Text("Join")
            }
            .font(.system(size: small ? 11 : 12, weight: .semibold))
            .padding(.horizontal, small ? 9 : 10)
            .frame(height: small ? 22 : 24)
            .background(Color.green.opacity(0.9), in: Capsule())
            .foregroundStyle(.white)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Join the meeting")
    }
}

/// The reminder's look, fed plain values: the island shows it from `CalendarStore`, the welcome with an example.
struct CalendarReminderContent: View {
    let event: CalendarEvent
    var onJoin: ((URL) -> Void)?
    /// The welcome's example always reads "in 5 min", whatever the clock says.
    var fixedCountdown: String?

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(event.color)).frame(width: 8, height: 8)
            // One glance size for everything (320): a long title glides once, like a song title.
            MarqueeText(trigger: event.id, gap: 44, bleed: 8) {
                Text(event.title)
                    .font(.system(size: 13, weight: .semibold))
            }
            if let fixedCountdown {
                countdownText(fixedCountdown)
            } else {
                TimelineView(.everyMinute) { context in
                    countdownText(CalendarRules.countdown(to: event.start, now: context.date))
                }
            }
            Spacer(minLength: 4)
            if event.meetingURL != nil {
                JoinButton(small: true) { if let url = event.meetingURL { onJoin?(url) } }
                    .allowsHitTesting(onJoin != nil)  // on the pill the click arrives through the window (see above)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, event.meetingURL == nil ? 14 : 6)
        .accessibilityElement(children: .combine)
    }

    private func countdownText(_ text: String) -> some View {
        Text("· \(text)")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

/// The reminder, 5 minutes before (6 s, the one glance size). The pill passes clicks through to your apps,
/// so only its Join end is clickable (the island's window handles that click).
struct CalendarReminderView: View {
    let store: CalendarStore
    /// Inside the open island (its banner) the Join button is live; on the pill the window handles the click.
    var onJoin: ((URL) -> Void)?

    var body: some View {
        if let event = store.reminding {
            CalendarReminderContent(event: event, onJoin: onJoin)
        }
    }

    /// How far from the right edge a click counts as Join: the button (about 46 pt) plus margin.
    static let joinZone: CGFloat = 64
}

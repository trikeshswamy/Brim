import Foundation

/// A calendar's colour in sRGB (0…1), for the event's bar and the reminder's dot.
public struct CalendarColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let fallback = CalendarColor(red: 0.25, green: 0.55, blue: 1)
}

/// One event from your calendars, reduced to what the island shows (F8).
public struct CalendarEvent: Equatable, Sendable, Identifiable {
    /// The calendar's identifier plus the start: repeating events share one identifier, and a moved event
    /// gets a new id (so it reminds you again at its new time).
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// You declined it: never shown, never reminds you (PRD F8).
    public var declined: Bool
    public var color: CalendarColor
    /// Zoom, Meet, Teams or FaceTime: the Join button.
    public var meetingURL: URL?
    /// Where a click on the event goes: the event itself in Apple's Calendar app (your question, 2026-10-05).
    public var openURL: URL?
    /// Which of your calendars it's in (`CalendarSource.id`): Settings → Calendar can switch a calendar off.
    public var calendarID: String?

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, declined: Bool = false,
                color: CalendarColor = .fallback, meetingURL: URL? = nil, openURL: URL? = nil, calendarID: String? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.declined = declined
        self.color = color
        self.meetingURL = meetingURL
        self.openURL = openURL
        self.calendarID = calendarID
    }

    /// Apple's Calendar app showing one event, from the event's calendar item identifier: `ical://ekevent/<id>`, the
    /// link MeetingBar uses too. Calendar opens on that event's day with the event selected.
    public static func calendarAppURL(itemID: String) -> URL? {
        guard !itemID.isEmpty, let path = itemID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "ical://ekevent/" + path)
    }
}

/// One of your calendars (iCloud, Google, Holidays, Birthdays…), to switch on or off in Settings → Calendar
/// (0.18.2; on the MVP checklist since P-4).
public struct CalendarSource: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// The account it belongs to ("iCloud", your Gmail address, "Other").
    public var account: String
    public var color: CalendarColor

    public init(id: String, title: String, account: String, color: CalendarColor) {
        self.id = id
        self.title = title
        self.account = account
        self.color = color
    }
}

/// Finds a Zoom, Meet, Teams or FaceTime link in an event's URL, location or notes (PRD F8: Join).
public enum MeetingLink {
    static let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "facetime.apple.com"]

    public static func find(in texts: [String?]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let url = match.url, url.scheme?.hasPrefix("http") == true,
                      let host = url.host?.lowercased() else { continue }
                if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
            }
        }
        return nil
    }
}

/// Which event the island shows, what its countdown says, and when the next reminder is due. Pure, so tested.
public enum CalendarRules {
    /// The reminder comes 5 minutes before the start (PRD F8).
    public static let reminderLead: TimeInterval = 5 * 60

    /// Events from the calendars you left on (Settings → Calendar). An event Brim can't place stays.
    public static func visible(_ events: [CalendarEvent], hidden: Set<String>) -> [CalendarEvent] {
        guard !hidden.isEmpty else { return events }
        return events.filter { event in event.calendarID.map { !hidden.contains($0) } ?? true }
    }

    /// Timed and not declined: the only events Brim shows or reminds you of (all-day ones never alert).
    static func counts(_ event: CalendarEvent) -> Bool { !event.isAllDay && !event.declined }

    /// The open island's event: the first one today that hasn't ended (one in progress stays until it ends).
    public static func next(in events: [CalendarEvent], now: Date, calendar: Calendar = .current) -> CalendarEvent? {
        events.filter { counts($0) && $0.end > now && ($0.start <= now || calendar.isDate($0.start, inSameDayAs: now)) }
            .min { $0.start < $1.start }
    }

    /// The Calendar tab's agenda (decision 7): today's timed events you haven't declined, in order, the ones that
    /// ended included (dimmed there), plus one still running from yesterday.
    public static func agenda(in events: [CalendarEvent], now: Date, calendar: Calendar = .current) -> [CalendarEvent] {
        events.filter { counts($0) && (calendar.isDate($0.start, inSameDayAs: now) || ($0.start <= now && $0.end > now)) }
            .sorted { $0.start < $1.start }
    }

    /// "in 5 min", "in 1 h 20 min", or "now" once it has started. Rounds up, so a reminder a few
    /// milliseconds late still says "in 5 min".
    public static func countdown(to start: Date, now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        guard minutes > 0 else { return "now" }
        guard minutes >= 60 else { return "in \(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "in \(hours) h" : "in \(hours) h \(rest) min"
    }

    /// The next reminder: 5 minutes before each upcoming event, soonest first, skipping ones already shown.
    /// An event already inside those 5 minutes (just added, or Brim just started) reminds you straight away.
    public static func nextReminder(in events: [CalendarEvent], now: Date, shown: Set<String>) -> (event: CalendarEvent, at: Date)? {
        events.filter { counts($0) && $0.start > now && !shown.contains($0.id) }
            .map { (event: $0, at: max($0.start.addingTimeInterval(-reminderLead), now)) }
            .min { $0.at < $1.at }
    }
}

/// Your calendars: EventKit (live) or a fake (tests).
@MainActor
public protocol CalendarService: AnyObject {
    var availability: Availability { get }
    /// Asks macOS the first time; afterwards returns the answer you gave.
    func requestAccess() async -> Bool
    /// Today's events, plus any still running from yesterday, from every calendar.
    func eventsToday() -> [CalendarEvent]
    /// Your calendars, for Settings → Calendar (empty without access).
    func calendars() -> [CalendarSource]
    /// Something changed: an event, the day, the time zone, or the Mac woke up.
    var changes: AsyncStream<Void> { get }
    func start()
}

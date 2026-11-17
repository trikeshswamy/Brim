import AppKit
import EventKit
import BrimCore

/// Your calendars through EventKit (P-4, F8): every account the Calendar app has (on the test Mac, checked
/// 2026-09-30: 11 Google/CalDAV, 3 iCloud, 1 subscribed, birthdays).
///
/// Never polls: EventKit's change notification, the day changing, the time zone changing and waking up are
/// the only triggers. Needs Calendar access (asked once) and, with the hardened runtime, the calendars
/// entitlement; without it macOS refuses silently, with no prompt.
public final class EventKitCalendarService: CalendarService {
    public let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let store = EKEventStore()
    private var observers: [NSObjectProtocol] = []

    public init() {
        (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Full access already given: Settings turns the calendar on at first only then, so no surprise prompt.
    public static var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    public var availability: Availability {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .ready
        case .notDetermined: .starting
        case .denied, .restricted, .writeOnly: .needsPermission
        @unknown default: .unavailable(reason: "Calendar access is in a state Brim doesn't know.")
        }
    }

    public func requestAccess() async -> Bool {
        let granted = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            store.requestFullAccessToEvents { granted, _ in done.resume(returning: granted) }
        }
        if granted { store.reset() }  // a store made before access was given may not see the calendars yet
        return granted
    }

    public func eventsToday() -> [CalendarEvent] {
        guard Self.isAuthorized else { return [] }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        // Includes events that started before today and are still running.
        let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
        return store.events(matching: predicate).map(Self.event)
    }

    public func calendars() -> [CalendarSource] {
        guard Self.isAuthorized else { return [] }
        return store.calendars(for: .event)
            .map { CalendarSource(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "Other",
                                  color: Self.color($0.cgColor)) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    public func start() {
        guard observers.isEmpty else { return }
        for name in [Notification.Name.EKEventStoreChanged, .NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.continuation.yield(()) }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.continuation.yield(()) }
        })
    }

    private static func event(_ event: EKEvent) -> CalendarEvent {
        let declined = event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
        let title = event.title ?? ""
        return CalendarEvent(id: "\(event.calendarItemIdentifier)|\(event.startDate.timeIntervalSince1970)",
                             title: title.isEmpty ? "Event" : title, start: event.startDate, end: event.endDate,
                             isAllDay: event.isAllDay, declined: declined, color: color(event.calendar?.cgColor),
                             meetingURL: MeetingLink.find(in: [event.url?.absoluteString, event.location, event.notes]),
                             openURL: CalendarEvent.calendarAppURL(itemID: event.calendarItemIdentifier),
                             calendarID: event.calendar?.calendarIdentifier)
    }

    private static func color(_ cgColor: CGColor?) -> CalendarColor {
        guard let cgColor, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let parts = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil)?.components,
              parts.count >= 3 else { return .fallback }
        return CalendarColor(red: Double(parts[0]), green: Double(parts[1]), blue: Double(parts[2]))
    }
}

import Foundation

/// One Focus timer you ran (feature 3, your picks 2026-10-02): kept on your Mac, one line each.
public struct FocusSession: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date
    /// The timer's length, "+1 min" included.
    public var planned: TimeInterval
    /// Time it actually ran: the whole length when it finished; up to the cancel when you stopped it. Paused time
    /// doesn't count.
    public var focused: TimeInterval
    /// Time's up (true), or you stopped it early (false).
    public var finished: Bool
    /// What it was for, picked when you started it ("Brim", "Reading"). Optional.
    public var label: String?

    public init(start: Date, end: Date, planned: TimeInterval, focused: TimeInterval, finished: Bool, label: String?) {
        self.start = start
        self.end = end
        self.planned = planned
        self.focused = focused
        self.finished = finished
        self.label = label
    }
}

/// What you wrote about a session when it ended, shown under it in Today's details (your ask, 2026-11-16).
public struct SessionNote: Codable, Equatable, Sendable {
    public var text: String
    /// 1–5, if you gave one.
    public var energy: Int?

    public init(text: String, energy: Int? = nil) {
        self.text = text
        self.energy = energy
    }

    /// "Wrote the intro · Energy 4".
    public var line: String {
        [text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty, energy.map { "Energy \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Today's and the last 7 days' focus, for the Timers tab.
public struct FocusSummary: Equatable, Sendable {
    public struct LabelTime: Equatable, Sendable {
        public var label: String
        public var seconds: TimeInterval
    }

    public var today: TimeInterval = 0
    public var todaySessions = 0
    public var lastSevenDays: TimeInterval = 0
    /// Today's time per label, most first (top 3).
    public var todayLabels: [LabelTime] = []

    public init() {}
}

/// Focus history's rules. Pure, so tested.
public enum FocusHistory {
    /// Shorter than this when you stop it: a mis-start, not a session.
    public static let minimumSession: TimeInterval = 60
    /// At most this many labels in Settings: a short list stays one click.
    public static let maximumLabels = 12

    /// The session a Focus timer leaves when it ends (`finished`) or you stop it; nil for breaks and mis-starts.
    public static func session(for item: TimerItem, endedAt: Date, finished: Bool) -> FocusSession? {
        guard item.kind == .focus else { return nil }
        let focused = finished ? item.state.total : max(0, item.state.total - item.state.remaining(at: endedAt))
        guard focused >= minimumSession else { return nil }
        return FocusSession(start: item.startedAt ?? endedAt.addingTimeInterval(-focused), end: endedAt,
                            planned: item.state.total, focused: focused, finished: finished, label: item.label)
    }

    /// "Today" is the calendar day of each session's end; "the last 7 days" are today and the 6 before.
    public static func summary(_ sessions: [FocusSession], now: Date, calendar: Calendar = .current) -> FocusSummary {
        var summary = FocusSummary()
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        var labels: [String: TimeInterval] = [:]
        for session in sessions where session.end >= weekStart && session.end <= now.addingTimeInterval(60) {
            summary.lastSevenDays += session.focused
            guard session.end >= today else { continue }
            summary.today += session.focused
            summary.todaySessions += 1
            if let label = session.label { labels[label, default: 0] += session.focused }
        }
        summary.todayLabels = labels.map { FocusSummary.LabelTime(label: $0.key, seconds: $0.value) }
            .sorted { ($0.seconds, $1.label) > ($1.seconds, $0.label) }
            .prefix(3).map { $0 }
        return summary
    }

    /// Where the time went, for Today's details: every label's total (sessions without one as "Unlabeled"), most
    /// first, equal times by name. Worked out once per draw: before 2026-11-17 each row sorted on its own and equal
    /// times fell in any order, so two rows could show the same label (your screenshot: Security+ twice, no Brim).
    public static func labelTimes(_ sessions: [FocusSession]) -> [FocusSummary.LabelTime] {
        var totals: [String: TimeInterval] = [:]
        for session in sessions { totals[session.label ?? "Unlabeled", default: 0] += session.focused }
        return totals.map { FocusSummary.LabelTime(label: $0.key, seconds: $0.value) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.label < $1.label }
    }

    /// Focus sessions that ended today, newest first. Kept separate from `summary` so the Timers tab can show the
    /// actual sessions behind its compact total without reimplementing the calendar-day rule.
    public static func todaySessions(_ sessions: [FocusSession], now: Date, calendar: Calendar = .current) -> [FocusSession] {
        let today = calendar.startOfDay(for: now)
        return sessions
            .filter { $0.end >= today && $0.end <= now.addingTimeInterval(60) }
            .sorted { $0.end > $1.end }
    }

    /// "2 h 15 min", "45 min", "1 h".
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// A label as you typed it, tidied; nil when empty.
    public static func cleaned(_ label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(24))
    }
}

/// Where sessions are kept. Live: a file on your Mac (BrimSystem); tests: a fake.
public protocol FocusHistoryService: Sendable {
    func load() async -> [FocusSession]
    func append(_ session: FocusSession) async
}

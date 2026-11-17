import Foundation
import Testing
@testable import BrimCore

/// Focus history (feature 3, your picks 2026-10-02): what counts, and today's / the last 7 days' totals.
struct FocusHistoryTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func focus(_ length: TimeInterval, startedAt: Date?, label: String? = nil) -> TimerItem {
        TimerItem(kind: .focus, state: .start(length: length, at: startedAt ?? t0), startedAt: startedAt, label: label)
    }

    @Test func aFinishedFocusTimerCountsWhole() {
        let item = focus(1500, startedAt: t0, label: "Brim")
        let session = FocusHistory.session(for: item, endedAt: t0.addingTimeInterval(1500), finished: true)
        #expect(session == FocusSession(start: t0, end: t0.addingTimeInterval(1500), planned: 1500, focused: 1500,
                                        finished: true, label: "Brim"))
    }

    /// Stopped early: only the time it ran; paused time doesn't count.
    @Test func aStoppedOneCountsWhatRan() {
        var item = focus(1500, startedAt: t0)
        item.state = item.state.paused(at: t0.addingTimeInterval(300))  // ran 5 min, then paused for an hour
        let session = FocusHistory.session(for: item, endedAt: t0.addingTimeInterval(3900), finished: false)
        #expect(session?.focused == 300)
        #expect(session?.finished == false)
    }

    @Test func breaksAndMisStartsDontCount() {
        let rest = TimerItem(kind: .rest, state: .start(length: 300, at: t0), startedAt: t0)
        #expect(FocusHistory.session(for: rest, endedAt: t0.addingTimeInterval(300), finished: true) == nil)
        #expect(FocusHistory.session(for: focus(1500, startedAt: t0), endedAt: t0.addingTimeInterval(30), finished: false) == nil)
    }

    /// Timers saved before 0.17 have no start time: it's worked out from the end.
    @Test func olderTimersStillCount() throws {
        let saved = Data(#"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"focus","state":{"total":600,"endsAt":0},"shownMilestones":[]}]"#.utf8)
        let items = try JSONDecoder().decode([TimerItem].self, from: saved)
        #expect(items.first?.startedAt == nil && items.first?.label == nil)
        let session = FocusHistory.session(for: focus(600, startedAt: nil), endedAt: t0.addingTimeInterval(600), finished: true)
        #expect(session?.start == t0)
    }

    @Test func todayAndTheLastSevenDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 18))!
        func session(daysAgo: Int, hour: Int, minutes: Double, label: String?) -> FocusSession {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            let end = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
            return FocusSession(start: end.addingTimeInterval(-minutes * 60), end: end, planned: minutes * 60,
                                focused: minutes * 60, finished: true, label: label)
        }
        let sessions = [session(daysAgo: 0, hour: 10, minutes: 25, label: "Brim"),
                        session(daysAgo: 0, hour: 12, minutes: 15, label: "Reading"),
                        session(daysAgo: 0, hour: 14, minutes: 25, label: "Brim"),
                        session(daysAgo: 1, hour: 20, minutes: 30, label: "Brim"),
                        session(daysAgo: 8, hour: 9, minutes: 60, label: "Old")]
        let summary = FocusHistory.summary(sessions, now: now, calendar: calendar)
        #expect(summary.today == 65 * 60)
        #expect(summary.todaySessions == 3)
        #expect(summary.lastSevenDays == 95 * 60)          // not the one 8 days ago
        #expect(summary.todayLabels.map(\.label) == ["Brim", "Reading"])
        #expect(summary.todayLabels.first?.seconds == TimeInterval(3000))  // Brim: 25 + 25 min
    }

    @Test func todaySessionsAreNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 18))!
        let todayStart = calendar.startOfDay(for: now)
        let older = FocusSession(start: todayStart.addingTimeInterval(3600), end: todayStart.addingTimeInterval(4200),
                                 planned: 600, focused: 600, finished: true, label: "Morning")
        let newer = FocusSession(start: todayStart.addingTimeInterval(10 * 3600), end: todayStart.addingTimeInterval(11 * 3600),
                                 planned: 600, focused: 600, finished: false, label: "Afternoon")
        let yesterday = FocusSession(start: todayStart.addingTimeInterval(-3600), end: todayStart.addingTimeInterval(-3000),
                                     planned: 600, focused: 600, finished: true, label: "Old")
        let result = FocusHistory.todaySessions([older, yesterday, newer], now: now, calendar: calendar)
        #expect(result.map(\.label) == ["Afternoon", "Morning"])
    }

    @Test func durationsAndLabelsReadWell() {
        #expect(FocusHistory.duration(45 * 60) == "45 min")
        #expect(FocusHistory.duration(3600) == "1 h")
        #expect(FocusHistory.duration(8100) == "2 h 15 min")
        #expect(FocusHistory.cleaned("  Brim  ") == "Brim")
        #expect(FocusHistory.cleaned("   ") == nil)
        #expect(FocusHistory.cleaned(String(repeating: "x", count: 40))?.count == 24)
    }
}

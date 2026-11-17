import Foundation
import Testing
@testable import BrimCore
@testable import BrimFeatures

/// Stands in for the history file.
actor FakeFocusHistory: FocusHistoryService {
    private(set) var appended: [FocusSession] = []
    var saved: [FocusSession] = []
    func load() async -> [FocusSession] { saved }
    func append(_ session: FocusSession) async { appended.append(session) }
}

private final class SilentTimerAlarm: TimerAlarm {
    func prepare() {}
    func ring(title: String, body: String) {}
    func silence() {}
}

/// Feature 3: the timer records Focus sessions with their label; your labels live in Settings.
struct FocusHistoryStoreTests {
    private func make() -> (TimerStore, FocusHistoryStore, FakeFocusHistory, UserDefaults) {
        let defaults = UserDefaults(suiteName: testSuiteName("brim.focus"))!
        let file = FakeFocusHistory()
        let history = FocusHistoryStore(service: file, defaults: defaults)
        let timer = TimerStore(island: IslandCoordinator(), alarm: SilentTimerAlarm(), defaults: defaults)
        timer.history = history
        return (timer, history, file, defaults)
    }

    /// Your ask, 2026-11-16: what you wrote when a session ended shows under it in Today's details, and is kept on
    /// your Mac (after a restart too).
    @Test func aSessionsNoteIsKeptAndShown() {
        let (_, history, file, defaults) = make()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let session = FocusSession(start: start, end: start.addingTimeInterval(1500), planned: 1500, focused: 1500,
                                   finished: true, label: "Brim")
        history.setNote(SessionNote(text: "  Wrote the intro ", energy: 4), for: session)
        #expect(history.note(for: session)?.line == "Wrote the intro · Energy 4")
        let reopened = FocusHistoryStore(service: file, defaults: defaults)
        #expect(reopened.note(for: session)?.energy == 4)
        history.setNote(SessionNote(text: " "), for: session)  // nothing written: no note
        #expect(history.note(for: session) == nil)
        #expect(SessionNote(text: "", energy: 2).line == "Energy 2")
    }

    /// Your screenshot, 2026-11-17: Security+ and Brim, a minute each, showed as Security+ twice.
    @Test func whereYourTimeWentListsEachLabelOnce() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        func session(_ label: String?, _ minutes: Double) -> FocusSession {
            FocusSession(start: start, end: start.addingTimeInterval(minutes * 60), planned: minutes * 60,
                         focused: minutes * 60, finished: true, label: label)
        }
        for _ in 0..<20 {  // equal times used to land in any order
            let times = FocusHistory.labelTimes([session("Security+", 1), session("Brim", 1), session(nil, 3)])
            #expect(times.map(\.label) == ["Unlabeled", "Brim", "Security+"])
        }
    }

    @Test func aFinishedFocusTimerIsRecordedWithItsLabel() async {
        let (timer, history, file, _) = make()
        var clock = Date()
        timer.now = { clock }
        history.addLabel("Brim")
        history.selectedLabel = "Brim"
        timer.start(length: 600, kind: .focus)
        clock = clock.addingTimeInterval(601)
        timer.start()  // looks at the timers again, as the wake-up does
        #expect(history.sessions.count == 1)
        #expect(history.sessions.first?.label == "Brim" && history.sessions.first?.finished == true)
        #expect(history.sessions.first?.focused == 600)
        for _ in 0..<100 where await file.appended.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(await file.appended.count == 1)            // and kept on disk
    }

    @Test func aStoppedOneIsRecordedForWhatRan() {
        let (timer, history, _, _) = make()
        var clock = Date()
        timer.now = { clock }
        timer.start(length: 1500, kind: .focus)
        clock = clock.addingTimeInterval(300)
        timer.cancel(timer.items[0].id)
        #expect(history.sessions.first?.focused == 300)
        #expect(history.sessions.first?.finished == false)
        #expect(history.sessions.first?.label == nil)      // none picked
    }

    @Test func breaksAndMisStartsAreNot() {
        let (timer, history, _, _) = make()
        var clock = Date()
        timer.now = { clock }
        timer.start(length: 300, kind: .rest)
        clock = clock.addingTimeInterval(301)
        timer.start()
        timer.start(length: 1500, kind: .focus)
        clock = clock.addingTimeInterval(20)
        timer.cancel(timer.items[0].id)
        #expect(history.sessions.isEmpty)
    }

    @Test func labelsAreTidyAndRemembered() {
        let (_, history, _, defaults) = make()
        history.addLabel("  Brim ")
        history.addLabel("brim")                           // already there, any case
        history.addLabel("Reading")
        history.selectedLabel = "Reading"
        #expect(history.labels == ["Brim", "Reading"])
        let again = FocusHistoryStore(service: FakeFocusHistory(), defaults: defaults)
        #expect(again.labels == ["Brim", "Reading"] && again.selectedLabel == "Reading")
        again.removeLabel("Reading")
        #expect(again.selectedLabel == nil)                 // a removed label isn't picked any more
    }
}

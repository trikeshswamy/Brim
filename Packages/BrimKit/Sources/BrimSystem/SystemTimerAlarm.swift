import AppKit
import UserNotifications
import BrimCore

/// The timer's end (PRD F9): the "Glass" sound every 3 s while "Time's up" shows (30 s at most), and one
/// notification that stays in Notification Center. Asks for notification permission once, at the first timer.
public final class SystemTimerAlarm: TimerAlarm {
    private var ringing: Task<Void, Never>?

    public init() {}

    public func prepare() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    public func ring(title: String, body: String) {
        silence()
        ringing = Task {
            for chime in 1...10 {
                // Logged, so a "no sound" report can be told apart from a chime drowned out by music.
                let played = NSSound(named: "Glass")?.play() ?? false
                Log.app.notice("Timer alarm: chime \(chime) \(played ? "played" : "failed", privacy: .public)")
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
            }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "brim.timer", content: content, trigger: nil))
    }

    public func silence() {
        ringing?.cancel()
        ringing = nil
    }
}

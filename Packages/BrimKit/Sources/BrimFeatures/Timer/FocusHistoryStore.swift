import Foundation
import Observation
import BrimCore

/// Focus history (feature 3, your picks 2026-10-02): the sessions on your Mac, your labels (typed once in Settings →
/// Timers), and the one picked for the next Focus timer ("For:" next to Start).
@Observable
public final class FocusHistoryStore {
    public private(set) var sessions: [FocusSession] = []
    /// Your notes, by the session's start (the last 100, on your Mac).
    public private(set) var notes: [Date: SessionNote] = [:]
    public private(set) var labels: [String]
    /// The label the next Focus timer gets; kept for the next one too (you usually go on with the same thing).
    public var selectedLabel: String? {
        didSet {
            defaults.set(selectedLabel, forKey: Key.selected)
            if selectedLabel != nil, selectedLabel != oldValue { Usage.note("focus.label.pick") }
        }
    }
    /// "Edit Labels…" in the Timers tab: opens Settings.
    @ObservationIgnored public var onEditLabels: (() -> Void)?

    @ObservationIgnored private let service: any FocusHistoryService
    @ObservationIgnored private let defaults: UserDefaults
    /// Tests set the clock by hand.
    @ObservationIgnored var now: () -> Date = Date.init

    public init(service: any FocusHistoryService, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        labels = defaults.stringArray(forKey: Key.labels) ?? []
        if let data = defaults.data(forKey: Key.notes),
           let saved = try? JSONDecoder().decode([NoteEntry].self, from: data) {
            notes = Dictionary(saved.map { ($0.start, $0.note) }, uniquingKeysWith: { _, last in last })
        }
        let selected = defaults.string(forKey: Key.selected)
        selectedLabel = selected.flatMap { labels.contains($0) ? $0 : nil }
    }

    public func start() {
        Task { [service] in
            let saved = await service.load()
            self.sessions = saved + self.sessions  // anything recorded meanwhile stays
        }
    }

    public var summary: FocusSummary { FocusHistory.summary(sessions, now: now()) }

    /// A Focus timer ended or was stopped (`TimerStore`).
    func record(_ session: FocusSession) {
        sessions.append(session)
        Usage.note(session.finished ? "focus.session.finished" : "focus.session.stopped")
        Task { [service] in await service.append(session) }
    }

    /// What you wrote when a session ended (the end-of-session box's Save). An empty note removes it.
    public func setNote(_ note: SessionNote, for session: FocusSession) {
        notes[session.start] = note.line.isEmpty ? nil : note
        let kept = notes.sorted { $0.key > $1.key }.prefix(Self.notesKept).map { NoteEntry(start: $0.key, note: $0.value) }
        notes = Dictionary(kept.map { ($0.start, $0.note) }, uniquingKeysWith: { _, last in last })
        defaults.set(try? JSONEncoder().encode(kept), forKey: Key.notes)
    }

    public func note(for session: FocusSession) -> SessionNote? { notes[session.start] }

    static let notesKept = 100

    private struct NoteEntry: Codable {
        let start: Date
        let note: SessionNote
    }

    /// From Settings: tidied, no duplicates (any case), at most `FocusHistory.maximumLabels`.
    public func addLabel(_ text: String) {
        guard let label = FocusHistory.cleaned(text), labels.count < FocusHistory.maximumLabels,
              !labels.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) else { return }
        labels.append(label)
        defaults.set(labels, forKey: Key.labels)
    }

    public func removeLabel(_ label: String) {
        labels.removeAll { $0 == label }
        defaults.set(labels, forKey: Key.labels)
        if selectedLabel == label { selectedLabel = nil }
    }

    public func editLabels() { onEditLabels?() }

    private enum Key {
        static let labels = "focus.labels"
        static let selected = "focus.selectedLabel"
        static let notes = "focus.notes"
    }
}

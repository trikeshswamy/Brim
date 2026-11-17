import SwiftUI
import BrimCore

private let timerOrange = Color.orange

/// The Timers tab (decision 7, your references, 2026-09-30): Focus | Break, a ruler to pick any length (scroll
/// with two fingers, or click a tick), Start and the length in big numbers, then every running timer.
/// Everything here updates only while the tab is on screen.
struct TimersTabView: View {
    @Bindable var timer: TimerStore

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                ModeSwitch(mode: $timer.mode)
                if let history = timer.history {
                    HStack {
                        Spacer()
                        FocusToday(history: history)
                    }
                    .padding(.trailing, 18)
                }
            }
            RulerPicker(minutes: $timer.pickedMinutes)
            HStack {
                Button(action: timer.startPicked) {
                    Text("Start")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(timerOrange)
                        .padding(.horizontal, 16)
                        .frame(height: 30)
                        .background(timerOrange.opacity(0.2), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!timer.canStartAnother)
                .opacity(timer.canStartAnother ? 1 : 0.4)
                .help(timer.canStartAnother ? "Start a \(timer.mode.title) timer" : "Five timers at most")
                if timer.mode == .focus, let history = timer.history {
                    FocusLabelMenu(history: history)
                }
                Spacer()
                Text(TimerRules.clock(TimeInterval(timer.pickedMinutes * 60)))
                    .font(.system(size: 28, weight: .semibold).monospacedDigit())
                    .foregroundStyle(timerOrange)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 18)
            if !timer.items.isEmpty {
                TimerList(timer: timer)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

/// "For: Brim ▾" (feature 3, your pick): the next Focus timer's label, from the list you keep in Settings → Timers.
/// A menu, so it works without the island taking keyboard focus.
private struct FocusLabelMenu: View {
    @Bindable var history: FocusHistoryStore
    @Environment(\.offscreenRender) private var offscreenRender

    var body: some View {
        if offscreenRender {
            // Snapshots can't draw a menu: the same words, drawn plainly.
            HStack(spacing: 3) {
                Text("For: \(history.selectedLabel ?? "—")").font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.secondary)
        } else {
            menu
        }
    }

    private var menu: some View {
        Menu {
            Button { history.selectedLabel = nil } label: {
                if history.selectedLabel == nil { Label("No label", systemImage: "checkmark") } else { Text("No label") }
            }
            if !history.labels.isEmpty { Divider() }
            ForEach(history.labels, id: \.self) { label in
                Button { history.selectedLabel = label } label: {
                    if history.selectedLabel == label { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
            Divider()
            Button(history.labels.isEmpty ? "Add Labels…" : "Edit Labels…", action: history.editLabels)
        } label: {
            Text("For: \(history.selectedLabel ?? "—")")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("What this Focus timer is for (kept in Focus history)")
        .accessibilityLabel("Label for the Focus timer")
    }
}

/// "Today 2 h 15 min" by the Focus | Break switch; hover for today's labels and the last 7 days.
private struct FocusToday: View {
    let history: FocusHistoryStore
    @State private var showingDetails = false

    var body: some View {
        let summary = history.summary
        if summary.today > 0 || summary.lastSevenDays > 0 {
            Button { showingDetails = true } label: {
                Text("Today \(FocusHistory.duration(summary.today))")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Self.detail(summary))
            .accessibilityLabel("Open today's focus details")
            .accessibilityValue(Self.detail(summary))
            .popover(isPresented: $showingDetails, arrowEdge: .top) {
                FocusTodayDetails(summary: summary,
                                  sessions: FocusHistory.todaySessions(history.sessions, now: .now),
                                  notes: history.notes)
            }
        }
    }

    static func detail(_ summary: FocusSummary) -> String {
        let sessions = summary.todaySessions == 1 ? "1 session" : "\(summary.todaySessions) sessions"
        var lines = ["Today: \(FocusHistory.duration(summary.today)) focused, \(sessions)"]
        if !summary.todayLabels.isEmpty {
            lines.append(summary.todayLabels.map { "\($0.label) \(FocusHistory.duration($0.seconds))" }.joined(separator: " · "))
        }
        lines.append("Last 7 days: \(FocusHistory.duration(summary.lastSevenDays))")
        return lines.joined(separator: "\n")
    }
}

/// The detail behind the compact Today total. It stays a popover so the Timers tab does not gain another top-level
/// page, while still answering the three useful questions: how much, what it was for, and which sessions happened.
private struct FocusTodayDetails: View {
    let summary: FocusSummary
    let sessions: [FocusSession]
    /// What you wrote when each ended, by its start.
    var notes: [Date: SessionNote] = [:]


    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Today")
                    .font(.headline)
                Text(FocusHistory.duration(summary.today))
                    .font(.system(size: 24, weight: .semibold).monospacedDigit())
                    .foregroundStyle(timerOrange)
            }

            let labelTimes = FocusHistory.labelTimes(sessions)
            if !labelTimes.isEmpty {
                detailSection("Where your time went") {
                    ForEach(labelTimes, id: \.label) { entry in
                        HStack {
                            Text(entry.label)
                                .lineLimit(1)
                            Spacer(minLength: 12)
                            Text(FocusHistory.duration(entry.seconds))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(.system(size: 12))
                    }
                }
            }

            detailSection("Sessions") {
                if sessions.isEmpty {
                    Text("No focus sessions today.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(sessions.indices, id: \.self) { index in
                                sessionRow(sessions[index])
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            }

            if summary.lastSevenDays > summary.today {
                Text("Last 7 days: \(FocusHistory.duration(summary.lastSevenDays))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
    }

    @ViewBuilder
    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func sessionRow(_ session: FocusSession) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: session.finished ? "checkmark.circle.fill" : "stop.circle")
                .foregroundStyle(session.finished ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.label ?? "Unlabeled")
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(FocusHistory.duration(session.focused))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text("\(session.start.formatted(date: .omitted, time: .shortened))–\(session.end.formatted(date: .omitted, time: .shortened)) · \(session.finished ? "Finished" : "Stopped")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                // Your note from when it ended (your ask, 2026-11-16).
                if let note = notes[session.start], !note.line.isEmpty {
                    Text(note.line)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
        .font(.system(size: 12))
    }
}

/// Focus | Break. Switching moves the ruler to 25 or 5 minutes.
private struct ModeSwitch: View {
    @Binding var mode: TimerKind

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TimerKind.allCases, id: \.self) { kind in
                Button { mode = kind } label: {
                    Text(kind.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(kind == mode ? timerOrange : Color.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 20)
                        .background(kind == mode ? timerOrange.opacity(0.2) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

/// A ruler of whole minutes, 1 to 180, under a fixed pointer. A native scroll view does the scrolling and
/// snapping (trackpad momentum included); only the ticks on screen exist (a lazy stack).
struct RulerPicker: View {
    @Binding var minutes: Int
    @Environment(\.offscreenRender) private var offscreenRender
    @State private var position: Int?
    private static let range = 1...180
    private static let tickWidth: CGFloat = 10

    var body: some View {
        VStack(spacing: 2) {
            Group {
                if offscreenRender {
                    staticRuler  // snapshots can't draw a scroll view
                } else {
                    GeometryReader { proxy in
                        // Half the width minus half a tick at each end: then tick n's centre is under the pointer
                        // exactly when the scroll offset is a whole number of ticks (`TickSnap`), whatever the width.
                        let side = max(0, proxy.size.width / 2 - Self.tickWidth / 2)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 0) {
                                Color.clear.frame(width: side)
                                ForEach(Self.range, id: \.self) { minute in
                                    Tick(minute: minute, lit: minute <= minutes, selected: minute == minutes)
                                        .frame(width: Self.tickWidth)
                                        .contentShape(Rectangle())
                                        .onTapGesture { withAnimation(.snappy) { minutes = minute } }
                                        .id(minute)
                                }
                                Color.clear.frame(width: side)
                            }
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(TickSnap(tickWidth: Self.tickWidth))
                        .scrollPosition(id: $position, anchor: .center)
                    }
                    .onAppear { position = minutes }
                    .onChange(of: position) { _, new in
                        if let new, new != minutes { minutes = new }
                    }
                    .onChange(of: minutes) { _, new in
                        if position != new { withAnimation(.snappy) { position = new } }
                    }
                }
            }
            .frame(height: 36)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                         .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            pointer
        }
        .accessibilityElement()
        .accessibilityLabel("Length")
        .accessibilityValue(TimerState(total: TimeInterval(minutes * 60), endsAt: nil).lengthText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: minutes = min(Self.range.upperBound, minutes + 1)
            case .decrement: minutes = max(Self.range.lowerBound, minutes - 1)
            @unknown default: break
            }
        }
    }

    @ViewBuilder
    private var pointer: some View {
        let triangle = Image(systemName: "arrowtriangle.up.fill")
            .font(.system(size: 8))
            .foregroundStyle(timerOrange)
        #if DEBUG
        if RulerProbe.enabled {
            triangle.onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).midX }) { x in
                RulerProbe.pointer = x
                RulerProbe.report()
            }
        } else {
            triangle
        }
        #else
        triangle
        #endif
    }

    private var staticRuler: some View {
        HStack(spacing: 0) {
            ForEach(max(1, minutes - 18)...min(180, minutes + 18), id: \.self) { minute in
                Tick(minute: minute, lit: minute <= minutes, selected: minute == minutes).frame(width: Self.tickWidth)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Stops the ruler with a tick's centre under the pointer, never its edge. Your screenshot, 2026-09-30: the pointer sat
/// half a tick left of 25, because `.viewAligned` lined up the tick's leading edge with the middle.
///
/// Only your scrolls are snapped. When Brim moves the ruler itself (opening, a click on a tick), the target is that
/// tick's own frame with a centre anchor, already exact: rounding it moved the ruler 5 pt (measured with the probe).
nonisolated struct TickSnap: ScrollTargetBehavior {
    let tickWidth: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard target.anchor == nil else { return }
        target.rect.origin.x = TimerRules.rulerSnap(target.rect.origin.x, tickWidth: tickWidth)
    }
}

#if DEBUG
/// Debug (`--ruler-probe`): logs where the selected tick's centre and the pointer land on screen, so their alignment is
/// measured in the running app (0.13.2, item 1), not just reasoned about.
@MainActor
enum RulerProbe {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--ruler-probe")
    static var pointer: CGFloat?
    static var tick: (minute: Int, x: CGFloat)?

    static func report() {
        guard enabled, let pointer, let tick else { return }
        Log.island.notice("Ruler probe: minute \(tick.minute, privacy: .public) tick \(tick.x, privacy: .public) pointer \(pointer, privacy: .public) off by \(tick.x - pointer, privacy: .public)")
    }
}
#endif

private struct Tick: View {
    let minute: Int
    let lit: Bool
    let selected: Bool

    var body: some View {
        #if DEBUG
        if RulerProbe.enabled {
            content.onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).midX }) { x in
                guard selected else { return }
                RulerProbe.tick = (minute, x)
                RulerProbe.report()
            }
        } else {
            content
        }
        #else
        content
        #endif
    }

    private var content: some View {
        VStack(spacing: 3) {
            Text(minute % 5 == 0 ? TimerRules.rulerLabel(minutes: minute) : " ")
                .font(.system(size: 10, weight: selected ? .bold : .semibold).monospacedDigit())
                .foregroundStyle(selected ? Color.primary : timerOrange.opacity(0.8))
                .fixedSize()
                .frame(width: 10, height: 12)
            Capsule()
                .fill(lit ? timerOrange : timerOrange.opacity(0.35))
                .frame(width: 2, height: minute % 5 == 0 ? 20 : 14)
        }
    }
}

/// The running timers, in the order you started them. Two show at once; more scroll.
private struct TimerList: View {
    let timer: TimerStore
    @Environment(\.offscreenRender) private var offscreenRender

    var body: some View {
        Group {
            if timer.items.count > 2 && !offscreenRender {
                ScrollView(.vertical, showsIndicators: false) { rows }
                    .frame(height: 64)
            } else {
                rows
            }
        }
        .padding(.horizontal, 12)
    }

    private var rows: some View {
        VStack(spacing: 4) {
            ForEach(timer.items) { item in
                TimerListRow(item: item, timer: timer)
            }
        }
    }
}

/// One timer: its ring, Focus or Break and its length, the time left, Pause/Resume, and Cancel spelled out
/// (an ✕ read as "close" and cancelled your timer once).
private struct TimerListRow: View {
    let item: TimerItem
    let timer: TimerStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(timerOrange.opacity(0.25), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: item.state.share(at: context.date))
                        .stroke(timerOrange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 16, height: 16)
                Text(item.label ?? item.kind.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)  // "Brim" for a labelled Focus timer
                Text(item.state.lengthText).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(TimerRules.clock(item.state.remaining(at: context.date)))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(timerOrange)
                    .opacity(item.state.isPaused ? 0.5 : 1)
                Button {
                    if item.state.isPaused { timer.resume(item.id) } else { timer.pause(item.id) }
                } label: {
                    Image(systemName: item.state.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.12), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(item.state.isPaused ? "Resume" : "Pause")
                Button { timer.cancel(item.id) } label: {
                    Text("Cancel")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Color.primary.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.kind.title) timer" + (item.label.map { ", \($0)" } ?? ""))
    }
}

import SwiftUI
import BrimCore

/// The welcome in the island's place, round 3 (your picks, 2026-11-11):
/// - three steps, Hello · Look · Ready, about 20 seconds, one line each in Brim's own voice;
/// - music first: Hello shows your song in the island (a made-up one if nothing plays), and moves on when you point;
/// - Look applies Notch, Liquid Glass or Black Pill as you click, so this card changes with it;
/// - Ready: four switches, all off; a permission is asked only when you flip its switch;
/// - it grows out of the pill and shrinks back into it; steps slide the way you go; no overshoot anywhere.
/// Its window is the app's `WelcomeController`.
public struct WelcomeView: View {
    let flow: WelcomeFlow
    let settings: IslandSettings
    /// What's playing, for Hello's preview. Nil (or nothing playing): a made-up song.
    let nowPlaying: NowPlayingStore?
    /// The pointer, measured from Brim's eyes (x right, y down): they follow it. Nil: they look straight ahead.
    let pointer: (() -> CGPoint?)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.offscreenRender) private var offscreenRender
    /// Grown out of the pill (set a frame after the window shows, so the growth is seen).
    @State private var grown = false
    @State private var contentHeight: CGFloat = 150
    /// Brim's eyes have opened (a beat after the pill appears, before the card grows).
    @State private var woke = false
    /// A switch was just turned on: one wink.
    @State private var winking = false

    public init(flow: WelcomeFlow, settings: IslandSettings, nowPlaying: NowPlayingStore? = nil,
                pointer: (() -> CGPoint?)? = nil) {
        self.flow = flow
        self.settings = settings
        self.nowPlaying = nowPlaying
        self.pointer = pointer
    }

    /// The row at the top of the card where Brim's eyes sit.
    static let faceRow: CGFloat = 30

    public static let width: CGFloat = 420
    /// The window's height: the tallest step (Ready) plus Glass's 6 pt gap, with room to spare.
    public static let windowHeight: CGFloat = 310
    /// Apple's default UI spring: critically damped, about 0.38 s.
    static let spring = Animation.spring(response: 0.38, dampingFraction: 1)

    public var body: some View {
        let appearance = settings.appearance
        let pill = IslandMetrics.pillSize(appearance: appearance)
        let open = (grown || offscreenRender) && flow.isShowing  // snapshots: the open card
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                page
                    .id(flow.step)
                    .transition(stepTransition)
            }
            .frame(width: Self.width, alignment: .top)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            .opacity(open ? 1 : 0)
            // Brim's eyes: in the middle of the pill as it wakes, then at the top of the card, following you.
            LiveBrimFace(mood: mood, pointer: pointer, eye: CGSize(width: 10, height: 12), spacing: 9)
                .frame(height: open ? Self.faceRow : pill.height)
        }
        // The shape: the pill's size while it grows out (or back in), the content's height while open.
        .frame(width: open ? Self.width : pill.width, height: open ? contentHeight : pill.height, alignment: .top)
        .clipped()
        .modifier(IslandSurfaceStyle(appearance: appearance, cornerRadius: open ? 24 : pill.height / 2,
                                     shoulder: appearance == .black ? 6 : 0))
        // A small nod when you point at the top: the one place the card bounces (it's Brim saying yes).
        .scaleEffect(flow.outcome == .on && !reduceMotion ? 1.03 : 1, anchor: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.5), value: flow.outcome)
        // Back in the pill's shape, it fades as the island takes its place (or, with nothing resting, simply goes).
        .opacity(flow.isShowing ? 1 : 0)
        .animation(.easeIn(duration: 0.18).delay(flow.isShowing ? 0 : 0.22), value: flow.isShowing)
        .padding(.top, appearance == .black ? 0 : 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)  // its window is fixed: hang from the top
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Self.spring, value: open)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Self.spring, value: flow.step)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Self.spring, value: contentHeight)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Self.spring, value: appearance)
        // Brim wakes first (eyes open in the pill), then the card grows out of it.
        // (Each time it shows: Settings → General → Show Welcome Again replays it.)
        .task(id: flow.isShowing) {
            guard flow.isShowing else {
                // Gone (it shrank into the pill and faded): ready to wake again next time.
                try? await Task.sleep(for: .milliseconds(600))
                if !Task.isCancelled { grown = false; woke = false }
                return
            }
            guard !offscreenRender, !reduceMotion else { woke = true; grown = true; return }
            try? await Task.sleep(for: .milliseconds(350))
            woke = true
            try? await Task.sleep(for: .milliseconds(550))
            grown = true
        }
        .onChange(of: flow.cheers) {
            winking = true
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                winking = false
            }
        }
        .onChange(of: flow.outcome) { _, outcome in
            // You pointed at the top: one soft tick, like the swipe between button pairs.
            if outcome == .on { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        // Ready: you allow Brim in System Settings, so it checks every second while it shows.
        .task(id: flow.step) {
            guard flow.step == .ready else { return }
            while !Task.isCancelled, flow.step == .ready {
                flow.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to Brim, step \(flow.step.rawValue + 1) of \(WelcomeFlow.Step.allCases.count)")
    }

    /// Asleep as the pill appears, awake once it's open; pleased when you point at the top and as it says goodbye;
    /// a wink when you turn a switch on.
    private var mood: BrimFace.Mood {
        if offscreenRender { return flow.outcome == .on ? .happy : .awake }
        if !flow.isShowing { return .happy }
        if !woke { return .asleep }
        if flow.outcome == .on { return .happy }
        return winking ? .wink : .awake
    }

    /// One step: the preview strip, one line, the step's choices, then the dots and the buttons.
    private var page: some View {
        let words = WelcomePage(step: flow.step, outcome: flow.outcome, look: settings.appearance,
                                restartPending: flow.restartPending)
        let busy = flow.outcome != nil
        return VStack(alignment: .leading, spacing: 12) {
            switch flow.step {
            case .hello: WelcomeMusicPreview(nowPlaying: nowPlaying, appearance: settings.appearance, open: true)
            case .look: WelcomeMusicPreview(nowPlaying: nowPlaying, appearance: settings.appearance, open: false)
            case .ready: EmptyView()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(words.title).font(.system(size: 15, weight: .semibold))
                // Over glass, flat grey reads poorly: the primary colour, a little lighter.
                Text(words.line).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                if let note = words.note {
                    Text(note).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary.opacity(0.9))
                        .padding(.top, 3)
                }
            }
            .contentTransition(.opacity)
            switch flow.step {
            case .hello: EmptyView()
            case .look: lookPicker
            case .ready: switches
            }
            HStack(spacing: 8) {
                dots
                Spacer()
                if let secondary = words.secondary {
                    Button(secondary) { flow.skip() }
                        .buttonStyle(WelcomeButtonStyle(filled: false))
                        .help(words.secondaryHelp ?? "")
                        .disabled(busy)
                }
                Button(words.primary) { flow.next() }
                    .buttonStyle(WelcomeButtonStyle(filled: true))
                    .help(words.primaryHelp ?? "")
                    .disabled(busy)
            }
        }
        .padding(.horizontal, 18).padding(.top, Self.faceRow + 2).padding(.bottom, 12)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Notch · Liquid Glass · Black Pill: a click applies it to the island (and this card) at once.
    private var lookPicker: some View {
        HStack(spacing: 6) {
            ForEach(WelcomePage.looks, id: \.self) { look in
                let chosen = settings.appearance == look
                Button { settings.appearance = look } label: {
                    Text(look == .liquidGlass ? "Glass" : look.title)
                        .font(.system(size: 13, weight: chosen ? .semibold : .medium))
                        .foregroundStyle(chosen ? AnyShapeStyle(Color.black) : AnyShapeStyle(.primary.opacity(0.8)))
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(chosen ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary.opacity(0.1)),
                                    in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
    }

    /// Ready's switches, all off on a first launch. Each asks macOS only when you turn it on.
    private var switches: some View {
        VStack(spacing: 2) {
            WelcomeSwitchRow(title: "Meeting reminders, with Join", status: calendarStatus,
                             help: "macOS asks to share your calendar. I read it on your Mac; nothing leaves it.",
                             isOn: Binding(get: { flow.calendar == .on || flow.calendar == .asking },
                                           set: { on in Task { await flow.setCalendar(on) } }))
            WelcomeSwitchRow(title: "AirPods battery", status: nil,
                             help: "macOS asks for Bluetooth, so I can read your AirPods' battery.",
                             isOn: Binding(get: { flow.airPods }, set: { flow.setAirPods($0) }))
            WelcomeSwitchRow(title: "Volume here, not in the corner", status: volumeStatus,
                             help: "Opens System Settings → Privacy & Security → Accessibility. It also lets me play and pause Safari videos.",
                             isOn: Binding(get: { flow.volume != .off }, set: { flow.setVolume($0) }))
            WelcomeSwitchRow(title: "Open Brim when I log in", status: nil, help: nil,
                             isOn: Binding(get: { flow.launchAtLogin }, set: { flow.launchAtLogin = $0 }))
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var calendarStatus: String? {
        switch flow.calendar {
        case .asking: "Waiting for macOS…"
        case .notAllowed: "Not allowed. Settings → Permissions can fix it."
        case .on, .off: nil
        }
    }

    private var volumeStatus: String? {
        switch flow.volume {
        case .waiting: "Allow Brim in System Settings, then come back."
        case .on: flow.restartPending ? "I restart once when you finish." : nil
        case .off: nil
        }
    }

    /// The next step comes in from the right and the last one leaves to the left; going back, the other way.
    /// Reduce Motion: a crossfade.
    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let shift: CGFloat = flow.forward ? 28 : -28
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: shift)),
                           removal: .opacity.combined(with: .offset(x: -shift)))
    }

    /// Where you are, and a way back: an earlier step's dot takes you there.
    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(WelcomeFlow.Step.allCases, id: \.self) { step in
                let current = step == flow.step
                let earlier = step.rawValue < flow.step.rawValue
                Button { flow.back(to: step) } label: {
                    Capsule().fill(.primary.opacity(current ? 0.9 : earlier ? 0.45 : 0.2))
                        .frame(width: current ? 14 : 6, height: 6)
                        .padding(.vertical, 6).padding(.horizontal, 1)  // a bigger target than the dot
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!earlier || flow.outcome != nil)
                .accessibilityLabel(earlier ? "Back to step \(step.rawValue + 1)" : "Step \(step.rawValue + 1)")
            }
        }
    }
}

/// One step's words (one short line each, Brim's own voice) and its buttons; details live in the hover text.
struct WelcomePage {
    var title: String
    var line: String
    var note: String?
    var primary: String
    var secondary: String?
    var primaryHelp: String?
    var secondaryHelp: String?

    /// The order on the picker: the notch look first, since it's what most MacBooks have.
    static let looks: [IslandAppearance] = [.black, .liquidGlass, .blackPill]

    init(step: WelcomeFlow.Step, outcome: WelcomeFlow.Outcome? = nil, look: IslandAppearance = .liquidGlass,
         restartPending: Bool = false) {
        switch (step, outcome) {
        case (.hello, .on?):
            self.init("That's it.", "Point there whenever you want me.", "Next", nil)
        case (.hello, nil):
            self.init("Hi, I'm Brim.", "Point at the top of your screen to open me.", "Next", "Skip")
            note = "3 steps · about 20 seconds"
            secondaryHelp = "Skip the welcome. Settings → General → Show Welcome Again brings it back."
        case (.look, _):
            let line = switch look {
            case .black: "Black, around the camera, like part of your Mac."
            case .liquidGlass: "Liquid Glass, just under the top edge."
            case .blackPill: "A black pill, just under the top edge."
            }
            self.init("Pick a look.", line, "Next", nil)
            primaryHelp = "You can change it later in Settings → Island."
        case (.ready, _):
            self.init("You're set.", "Click the cover for full screen. Right-click me for more.",
                      restartPending ? "Finish & Restart" : "Done", nil)
            primaryHelp = "Everything here is also in Settings."
        }
    }

    private init(_ title: String, _ line: String, _ primary: String, _ secondary: String?) {
        self.title = title
        self.line = line
        self.primary = primary
        self.secondary = secondary
    }
}

/// One of Ready's switches: what you get, and under it a short status while macOS is involved.
private struct WelcomeSwitchRow: View {
    let title: String
    let status: String?
    let help: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let status {
                    Text(status).font(.system(size: 11)).foregroundStyle(.primary.opacity(0.65))
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .toggleStyle(WelcomeSwitchStyle(label: title))
                .labelsHidden()
        }
        .padding(.vertical, 5)
        .help(help ?? "")
        .animation(.easeInOut(duration: 0.2), value: status)
    }
}

/// A strip of screen top with the music in the island: Hello shows it open as a song starts (art · title · artist ·
/// bars), Look shows the resting pill in the look you picked. Your song if one plays; otherwise a made-up one.
struct WelcomeMusicPreview: View {
    let nowPlaying: NowPlayingStore?
    let appearance: IslandAppearance
    /// Hello: the wide "song starts" pill. Look: the resting pill.
    let open: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.offscreenRender) private var offscreenRender
    @State private var arrivedState = false
    private var arrived: Bool { arrivedState || offscreenRender }

    var body: some View {
        ZStack(alignment: .top) {
            // A dim, warm dusk (the same family as the site's footage), not the purple it was (2026-11-11).
            LinearGradient(colors: [Color(red: 0.16, green: 0.17, blue: 0.24), Color(red: 0.55, green: 0.36, blue: 0.27)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            island
        }
        .frame(width: WelcomeView.width - 36, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, .dark)  // a dark wallpaper strip: the island's content reads as it does on yours
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { arrivedState = true; return }
            withAnimation(WelcomeView.spring.delay(0.25)) { arrivedState = true }
        }
    }

    private var pill: CGSize { IslandMetrics.pillSize(appearance: appearance) }
    private var song: NowPlaying? { nowPlaying?.item }

    private var island: some View {
        let width = open ? IslandMetrics.glanceWidth : pill.width
        return content
            .frame(width: width, height: pill.height)
            .modifier(IslandSurfaceStyle(appearance: appearance, cornerRadius: pill.height / 2,
                                         shoulder: appearance == .black ? 6 : 0))
            .padding(.top, appearance == .black ? 0 : 6)
            .offset(y: arrived ? 0 : -(pill.height + 8))
            .animation(WelcomeView.spring, value: appearance)
    }

    @ViewBuilder
    private var content: some View {
        if let nowPlaying, song != nil {
            if open {
                CompactMediaView(store: nowPlaying)
            } else {
                KeptMusicView(store: nowPlaying, appearance: appearance)
            }
        } else {
            sample
        }
    }

    /// A made-up song, drawn like the pill: art, title and artist (open only), bars.
    private var sample: some View {
        let art: CGFloat = open ? 20 : IslandMetrics.pillArtSize(appearance: appearance)
        return HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.5, blue: 0.7), Color(red: 0.48, green: 0.3, blue: 1)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: art, height: art)
            if open {
                Text("Midnight Drive").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text("The Night Shift").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                ForEach(Array([0.5, 0.9, 0.6, 1, 0.45].enumerated()), id: \.offset) { _, height in
                    Capsule().fill(Color(red: 0.83, green: 0.42, blue: 1)).frame(width: 2.5, height: 14 * height)
                }
            }
        }
        .lineLimit(1)
        .padding(.horizontal, open ? 11 : (appearance == .black ? 8 : 9))
    }
}

/// One white button with dark text on every step (your pick), and a quiet grey one beside it. They answer on press,
/// not on release: a quick 3% squeeze (apple-design §1). macOS's own glass buttons draw as inactive here, because
/// Brim is never the active app.
private struct WelcomeButtonStyle: ButtonStyle {
    let filled: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: filled ? .semibold : .medium))
            .foregroundStyle(filled ? AnyShapeStyle(Color.black) : AnyShapeStyle(.primary.opacity(0.8)))
            .padding(.horizontal, filled ? 14 : 12).padding(.vertical, 6)
            .background(filled ? AnyShapeStyle(Color.white.opacity(configuration.isPressed ? 0.85 : 1))
                               : AnyShapeStyle(.primary.opacity(configuration.isPressed ? 0.16 : 0.1)),
                        in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .opacity(isEnabled ? 1 : 0.55)
            .contentShape(Capsule())
    }
}

/// Ready's switches, drawn by Brim: macOS's own switch draws grey (as if off) here, because Brim is never the
/// active app (seen on screen, 2026-10-26).
private struct WelcomeSwitchStyle: ToggleStyle {
    var label = "Open Brim when I log in"

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? Color.green : Color.primary.opacity(0.25))
                .frame(width: 32, height: 19)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 15, height: 15).padding(2)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                }
                .animation(.spring(response: 0.25, dampingFraction: 1), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

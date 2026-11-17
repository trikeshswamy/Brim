import AppKit
import SwiftUI
import Testing
@testable import BrimCore
@testable import BrimFeatures

/// Mockups for decisions 7–8 (2026-09-30): the open island's tabs (inside vs floating), the Timers and
/// Calendar tabs, and the side bubbles with their pull-out. Stand-ins drawn at real sizes, made-up content.
/// `BRIM_SNAPSHOTS=<folder> swift test --filter TrayMockupTests` writes tray-1-tabs.png and tray-2-bubbles.png.
@MainActor
struct TrayMockupTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    @Test(.enabled(if: folder != nil)) func renderTrayMockups() throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))

        let tabs = VStack(alignment: .leading, spacing: 22) {
            row("Tabs A · inside the island, icons + labels (one shape; +36 pt)", [
                Screen(label: "Music tab · 420 × 206", height: 250) {
                    Open(height: 206) { VStack(spacing: 0) { MusicStandIn(); TabBar(selected: 0) } }
                },
                Screen(label: "Timers tab · 420 × 252 · two timers running", height: 290) {
                    Open(height: 252) { VStack(spacing: 0) { TimersPage(); TabBar(selected: 1) } }
                },
            ])
            row("Tabs B · floating below the island, icons only (like your reference; a second shape)", [
                Screen(label: "Music · island 420 × 170 + tab bar", height: 250) {
                    VStack(spacing: 8) { Open(height: 170) { MusicStandIn() }; FloatingTabBar(selected: 0) }
                },
                Screen(label: "Calendar tab (same in A and B) · 420 × 214 in A", height: 290) {
                    Open(height: 214) { VStack(spacing: 0) { CalendarPage(); TabBar(selected: 2) } }
                },
            ])
        }
        try save(tabs, to: out.appendingPathComponent("tray-1-tabs.png"))

        let bubbles = VStack(alignment: .leading, spacing: 22) {
            row("Side bubbles · left: keep-awake (a mode that's on) · right: countdowns (timers, a class soon)", [
                Screen(label: "Keep-awake + a timer · Glass") { Resting(glass: true, left: .coffee, right: .timer(minutes: 18, share: 0.72, extra: 0)) },
                Screen(label: "Same · Black (floating, no rims)") { Resting(glass: false, left: .coffee, right: .timer(minutes: 18, share: 0.72, extra: 0)) },
            ])
            row("", [
                Screen(label: "Class in 8 min (its calendar's colour)") { Resting(glass: true, left: nil, right: .classSoon(minutes: 8)) },
                Screen(label: "3 timers + a class: the soonest shows, \"+3\" for the rest") { Resting(glass: true, left: .coffee, right: .timer(minutes: 4, share: 0.2, extra: 3)) },
            ])
            row("Pull-out (0.45 s spring): tucked behind the pill's end → stretched on the way → settles 8 pt out", [
                Screen(label: "1 · starting to come out") { PullOut(progress: 0.25) },
                Screen(label: "2 · pulling out, stretched") { PullOut(progress: 0.55) },
                Screen(label: "3 · a touch past, then back (the spring)") { PullOut(progress: 1.08) },
                Screen(label: "4 · settled · collapsing plays it backwards") { PullOut(progress: 1) },
            ])
        }
        try save(bubbles, to: out.appendingPathComponent("tray-2-bubbles.png"))
    }

    private func row(_ title: String, _ screens: [Screen]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty { Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white) }
            HStack(alignment: .top, spacing: 16) { ForEach(screens.indices, id: \.self) { screens[$0] } }
        }
    }

    private func save(_ sheet: some View, to url: URL) throws {
        let view = sheet.padding(28).background(Color(white: 0.09))
            .environment(\.offscreenRender, true).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}

private let orange = Color.orange
private let classBlue = Color(red: 0.25, green: 0.55, blue: 1)

private struct Screen: View {
    let label: String
    var height: CGFloat = 80
    let content: AnyView
    init(label: String, height: CGFloat = 80, @ViewBuilder content: () -> some View) {
        self.label = label
        self.height = height
        self.content = AnyView(content())
    }
    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.42), Color(red: 0.36, green: 0.2, blue: 0.4)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                content
            }
            .frame(width: 480, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
        }
    }
}

/// The open island (Liquid Glass stand-in), floating 6 pt below the edge.
private struct Open: View {
    let height: CGFloat
    let content: AnyView
    init(height: CGFloat, @ViewBuilder content: () -> some View) {
        self.height = height
        self.content = AnyView(content())
    }
    var body: some View {
        content
            .frame(width: 420, height: height)
            .modifier(IslandSurfaceStyle(appearance: .liquidGlass, cornerRadius: 24, shoulder: 0))
            .padding(.top, 6)
    }
}

private struct TabBar: View {
    let selected: Int
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array([("music.note", "Music"), ("timer", "Timers"), ("calendar", "Calendar")].enumerated()), id: \.offset) { index, tab in
                VStack(spacing: 2) {
                    Image(systemName: tab.0).font(.system(size: 13, weight: .semibold))
                    Text(tab.1).font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(index == selected ? (index == 1 ? orange : Color.primary) : Color.secondary)
                .frame(width: 70, height: 30)
                .background(index == selected ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
            }
            Spacer()
            // Keep-awake: a switch, not a tab. Lit while on.
            Image(systemName: "cup.and.saucer.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(orange)
                .frame(width: 30, height: 30).background(orange.opacity(0.18), in: Circle())
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .padding(.bottom, 4)
    }
}

private struct FloatingTabBar: View {
    let selected: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(["music.note", "timer", "calendar", "cup.and.saucer.fill"].enumerated()), id: \.offset) { index, symbol in
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(index == selected ? Color.primary : (index == 3 ? orange : Color.secondary))
                    .frame(width: 34, height: 26)
                    .background(index == selected ? Color.primary.opacity(0.14) : .clear, in: Capsule())
            }
        }
        .padding(4)
        .modifier(IslandSurfaceStyle(appearance: .liquidGlass, cornerRadius: 17, shoulder: 0))
    }
}

private struct MusicStandIn: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [Color(red: 0.93, green: 0.42, blue: 0.62), Color(red: 0.36, green: 0.24, blue: 0.72)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("maybe i was wrong about you").font(.system(size: 14, weight: .semibold))
                    Text("Nora Vale").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Text("0:51").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                Capsule().fill(Color.primary.opacity(0.2)).frame(height: 4)
                    .overlay(alignment: .leading) { Capsule().fill(Color.primary.opacity(0.8)).frame(width: 80, height: 4) }
                Text("-2:25").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 30) {
                Image(systemName: "backward.fill").font(.system(size: 16, weight: .semibold))
                Image(systemName: "pause.fill").font(.system(size: 22, weight: .semibold))
                Image(systemName: "forward.fill").font(.system(size: 16, weight: .semibold))
            }
        }
        .padding(16)
    }
}

/// Focus | Break, the ruler, the time and Start (your references), then the running timers.
private struct TimersPage: View {
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                Text("Focus").font(.system(size: 11, weight: .semibold)).foregroundStyle(orange)
                    .padding(.horizontal, 12).frame(height: 20).background(orange.opacity(0.2), in: Capsule())
                Text("Break").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).frame(height: 20)
            }
            .padding(2).background(Color.primary.opacity(0.06), in: Capsule())
            .padding(.top, 10)
            Ruler(value: 25)
            HStack {
                Text("Start").font(.system(size: 13, weight: .semibold)).foregroundStyle(orange)
                    .padding(.horizontal, 16).frame(height: 30).background(orange.opacity(0.2), in: Capsule())
                Spacer()
                Text("25:00").font(.system(size: 28, weight: .semibold).monospacedDigit()).foregroundStyle(orange)
            }
            .padding(.horizontal, 18)
            VStack(spacing: 4) {
                RunningRow(name: "Focus", left: "18:42", share: 0.75)
                RunningRow(name: "Laundry", left: "1:04:10", share: 0.4)
            }
            .padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
    }
}

private struct Ruler: View {
    let value: Int
    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(0..<37) { index in
                    let minute = value - 18 + index
                    VStack(spacing: 3) {
                        Text(minute % 5 == 0 && minute > 0 ? "\(minute)" : " ")
                            .font(.system(size: 10, weight: minute == value ? .bold : .semibold).monospacedDigit())
                            .foregroundStyle(minute == value ? Color.primary : orange.opacity(0.8))
                            .fixedSize()
                            .frame(width: 10, height: 12)
                        Capsule().fill(minute <= value ? orange : orange.opacity(0.35))
                            .frame(width: 2, height: minute % 5 == 0 ? 20 : 14)
                    }
                    .frame(width: 10)
                }
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                         .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            Image(systemName: "arrowtriangle.up.fill").font(.system(size: 8)).foregroundStyle(orange)
        }
    }
}

private struct RunningRow: View {
    let name: String
    let left: String
    let share: Double
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(orange.opacity(0.25), lineWidth: 2.5)
                Circle().trim(from: 0, to: share).stroke(orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .frame(width: 16, height: 16)
            Text(name).font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(left).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(orange)
            Image(systemName: "pause.fill").font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22).background(Color.primary.opacity(0.12), in: Circle())
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22).background(Color.primary.opacity(0.12), in: Circle())
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Today's whole agenda, the date and time on top.
private struct CalendarPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("15:24").font(.system(size: 20, weight: .semibold).monospacedDigit())
                Text("Wednesday, 30 September").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 12)
            Agenda(time: "13:00", title: "Operating Systems", detail: "ended", color: .purple, dim: true)
            Agenda(time: "16:00", title: "Design Review · Weekly", detail: "in 36 min", color: classBlue, join: true)
            Agenda(time: "18:30", title: "Gym", detail: "in 3 h 6 min", color: .green)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
    }
}

private struct Agenda: View {
    let time: String
    let title: String
    let detail: String
    let color: Color
    var dim = false
    var join = false
    var body: some View {
        HStack(spacing: 9) {
            Text(time).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if join {
                Label("Join", systemImage: "video.fill").font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9).frame(height: 22).background(Color.green.opacity(0.9), in: Capsule()).foregroundStyle(.white)
            }
        }
        .opacity(dim ? 0.45 : 1)
    }
}

private enum Side { case coffee, timer(minutes: Int, share: Double, extra: Int), classSoon(minutes: Int) }

/// The music pill with a bubble on each side, placed as the island will place them.
private struct Resting: View {
    let glass: Bool
    let left: Side?
    let right: Side?
    var body: some View {
        let pill = glass ? CGSize(width: 128, height: 34) : CGSize(width: 185, height: 32)
        let side: CGFloat = glass ? 37 : 30
        let reach = pill.width / 2 + (glass ? 8 : 18) + side / 2
        let top: CGFloat = glass ? 4.5 : 4
        ZStack(alignment: .top) {
            if let left { Bubble(side: left, glass: glass, size: side).padding(.top, top).offset(x: -reach) }
            if let right { Bubble(side: right, glass: glass, size: side).padding(.top, top).offset(x: reach) }
            Pill(glass: glass, size: pill)
        }
    }
}

private struct Pill: View {
    let glass: Bool
    let size: CGSize
    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size.height - 10, height: size.height - 10)
            Spacer()
            WaveformView(isPlaying: true, tint: TintColor(hue: 0.9, saturation: 0.55, brightness: 0.95))
        }
        .padding(.horizontal, glass ? 5 : 8)
        .frame(width: size.width, height: size.height)
        .modifier(IslandSurfaceStyle(appearance: glass ? .liquidGlass : .black, cornerRadius: size.height / 2, shoulder: glass ? 0 : 6))
        .padding(.top, glass ? 6 : 0)
    }
}

private struct Bubble: View {
    let side: Side
    let glass: Bool
    let size: CGFloat
    var body: some View {
        ZStack {
            if !glass { Circle().fill(Color.black) }
            switch side {
            case .coffee:
                Image(systemName: "cup.and.saucer.fill").font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(orange)
            case .timer(let minutes, let share, _):
                ring(color: orange, share: share, label: "\(minutes)")
            case .classSoon(let minutes):
                ring(color: classBlue, share: Double(minutes) / 10, label: "\(minutes)")
            }
        }
        .frame(width: size, height: size)
        .modifier(GlassIf(glass: glass, size: size))
        .overlay(alignment: .topTrailing) {
            if case .timer(_, _, let extra) = side, extra > 0 {
                Text("+\(extra)").font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 4).frame(height: 14).background(orange, in: Capsule())
                    .offset(x: 6, y: -4)
            }
        }
    }

    private func ring(color: Color, share: Double, label: String) -> some View {
        ZStack {
            Circle().inset(by: glass ? 5 : 1.5).stroke(color.opacity(0.25), lineWidth: 3)
            Circle().inset(by: glass ? 5 : 1.5).trim(from: 0, to: share)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
            Text(label).font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(color)
        }
    }
}

private struct GlassIf: ViewModifier {
    let glass: Bool
    let size: CGFloat
    func body(content: Content) -> some View {
        if glass {
            content.modifier(IslandSurfaceStyle(appearance: .liquidGlass, cornerRadius: size / 2, shoulder: 0))
        } else {
            content
        }
    }
}

/// One frame of the pull-out: 0 tucked behind the pill's right end, 1 settled 8 pt out.
private struct PullOut: View {
    let progress: CGFloat
    var body: some View {
        let pill = CGSize(width: 128, height: 34)
        let side: CGFloat = 37
        let settled = pill.width / 2 + 8 + side / 2
        let tucked = pill.width / 2 - side / 2
        // On the way it stretches sideways (up to 1.35×) and is a little shorter; round again when it settles.
        let stretch = 1 + 0.35 * sin(min(progress, 1) * .pi)
        let x = tucked + (settled - tucked) * progress
        ZStack(alignment: .top) {
            // Only the part outside the pill's outline shows, so it truly comes out from behind the pill
            // (glass is see-through, so "behind" alone isn't enough).
            ZStack(alignment: .top) {
                Bubble(side: .timer(minutes: 25, share: 1, extra: 0), glass: true, size: side)
                    .scaleEffect(x: stretch, y: 1 / sqrt(stretch))
                    .padding(.top, 4.5)
                    .offset(x: x)
            }
            .frame(width: 480, height: 80, alignment: .top)
            .mask {
                ZStack(alignment: .top) {
                    Rectangle()
                    Capsule().frame(width: pill.width, height: pill.height).padding(.top, 6).blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            Pill(glass: true, size: pill)
        }
    }
}

/// The real Timers tab (step 2), drawn by Brim's own views in Black (renders exactly), with two timers running.
/// `BRIM_SNAPSHOTS=<folder> swift test --filter TimersTabSnapshotTests` writes timers-tab.png.
@MainActor
struct TimersTabSnapshotTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    @Test(.enabled(if: folder != nil)) func renderTimersTab() throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let name = testSuiteName("brim.snapshots")
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let timer = TimerStore(island: IslandCoordinator(), alarm: QuietAlarmForTab(), defaults: defaults)
        // Feature 3: a label picked, and two sessions today (Brim 50 min, Reading 15 min).
        let history = FocusHistoryStore(service: FakeFocusHistory(), defaults: defaults)
        history.addLabel("Brim")
        history.selectedLabel = "Brim"
        let end = Date().addingTimeInterval(-600)
        history.record(FocusSession(start: end.addingTimeInterval(-3000), end: end, planned: 3000, focused: 3000, finished: true, label: "Brim"))
        history.record(FocusSession(start: end.addingTimeInterval(-900), end: end, planned: 900, focused: 900, finished: false, label: "Reading"))
        timer.history = history
        timer.start(length: 25 * 60, kind: .focus)
        timer.start(length: 64 * 60 + 10, kind: .focus)
        let size = IslandMetrics.size(for: .expanded(.timers), appearance: .black, timerRows: 2)
        let view = ZStack(alignment: .top) {
            Color(white: 0.13)
            VStack(spacing: 0) {
                BrimFeatures.TabBar(selected: .timers, onSelect: { _ in })
                    .padding(.top, 6)
                    .frame(height: IslandMetrics.tabBarHeight, alignment: .top)
                TimersTabView(timer: timer).frame(maxHeight: .infinity)
            }
            .frame(width: size.width, height: size.height)
            .modifier(IslandSurfaceStyle(appearance: .black, cornerRadius: 24, shoulder: 6))
        }
        .frame(width: 460, height: 280)
        .environment(\.colorScheme, .dark)
        .environment(\.offscreenRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent("timers-tab.png"))
    }
}

private final class QuietAlarmForTab: TimerAlarm {
    func prepare() {}
    func ring(title: String, body: String) {}
    func silence() {}
}

/// The real side bubbles (step 3), drawn by the real island in Black (renders exactly): music playing, two timers,
/// and a class in 8 minutes. `BRIM_SNAPSHOTS=<folder> swift test --filter SideBubblesSnapshotTests` writes side-bubbles.png.
@MainActor
struct SideBubblesSnapshotTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    @Test(.enabled(if: folder != nil)) func renderSideBubbles() async throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let name = testSuiteName("brim.snapshots")
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = IslandSettings(defaults: defaults)
        settings.appearance = .black
        let clock = Date().addingTimeInterval(4)  // past the new song's 3 s peek
        let island = IslandCoordinator(now: { clock })
        let nowPlaying = NowPlayingStore(service: FakeNowPlayingService(), island: island)
        nowPlaying.handle(.item(NowPlaying(title: "Lantern", artist: "Milo Hart", bundleIdentifier: "com.spotify.client",
                                           isPlaying: true, duration: 196, elapsed: 51, timestamp: .now)))
        island.setKeepPillVisible(true)
        let timer = TimerStore(island: island, alarm: QuietAlarmForTab(), defaults: defaults)
        timer.start(length: 25 * 60)
        timer.start(length: 60 * 60)
        let calendarService = FakeCalendar()
        calendarService.events = [CalendarEvent(id: "class", title: "Lecture", start: Date().addingTimeInterval(8 * 60),
                                                end: Date().addingTimeInterval(68 * 60))]
        let calendar = CalendarStore(service: calendarService, island: island)
        calendar.remindersEnabled = false
        await calendar.setEnabled(true)
        island.reevaluate()
        let root = IslandRootView(coordinator: island, nowPlaying: nowPlaying, hud: HUDStore(volume: FakeVolumeService(), island: island),
                                  lyrics: LyricsStore(service: FakeLyricsService(answer: .notFound), nowPlaying: nowPlaying),
                                  modes: PlayerModesStore(service: FakePlayerControls(PlayerModes(shuffle: false, repeatMode: .off)), nowPlaying: nowPlaying),
                                  settings: settings, actions: .none, calendar: calendar, timer: timer)
        let view = ZStack(alignment: .top) { Color(white: 0.13); root }
            .frame(width: IslandMetrics.panelSize.width, height: 80, alignment: .top)
            .clipped()
            .environment(\.colorScheme, .dark)
            .environment(\.offscreenRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent("side-bubbles.png"))
        #expect(island.surface == .compact(.keptMusic))
    }
}

/// The real Calendar tab (step 4) in Black: an ended class, one running now, one to come with Join.
/// `BRIM_SNAPSHOTS=<folder> swift test --filter CalendarTabSnapshotTests` writes calendar-tab.png.
@MainActor
struct CalendarTabSnapshotTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    @Test(.enabled(if: folder != nil)) func renderCalendarTab() async throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let now = Date()
        let service = FakeCalendar()
        service.events = [
            CalendarEvent(id: "a", title: "Operating Systems", start: now.addingTimeInterval(-3 * 3600), end: now.addingTimeInterval(-2 * 3600),
                          color: CalendarColor(red: 0.6, green: 0.35, blue: 0.9)),
            CalendarEvent(id: "b", title: "Library study block", start: now.addingTimeInterval(-20 * 60), end: now.addingTimeInterval(40 * 60),
                          color: CalendarColor(red: 0.95, green: 0.6, blue: 0.2)),
            CalendarEvent(id: "c", title: "Design Review · Weekly", start: now.addingTimeInterval(36 * 60), end: now.addingTimeInterval(96 * 60),
                          meetingURL: URL(string: "https://meet.google.com/abc-defg-hij")),
        ]
        let calendar = CalendarStore(service: service, island: IslandCoordinator())
        calendar.remindersEnabled = false
        await calendar.setEnabled(true)
        let size = IslandMetrics.size(for: .expanded(.calendar), appearance: .black, agendaRows: calendar.agenda.count)
        let view = ZStack(alignment: .top) {
            Color(white: 0.13)
            VStack(spacing: 0) {
                BrimFeatures.TabBar(selected: .calendar, onSelect: { _ in })
                    .padding(.top, 6)
                    .frame(height: IslandMetrics.tabBarHeight, alignment: .top)
                CalendarTabView(actions: .none, calendar: calendar, showsEvent: true).frame(maxHeight: .infinity)
            }
            .frame(width: size.width, height: size.height)
            .modifier(IslandSurfaceStyle(appearance: .black, cornerRadius: 24, shoulder: 6))
        }
        .frame(width: 460, height: 230, alignment: .top)
        .environment(\.colorScheme, .dark)
        .environment(\.offscreenRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent("calendar-tab.png"))
    }
}

/// Fix check (2026-09-30): the longest lyrics message in the open island, drawn by the real view.
/// `BRIM_SNAPSHOTS=<folder> swift test --filter LyricsMessageSnapshotTests` writes lyrics-message.png.
@MainActor
struct LyricsMessageSnapshotTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    @Test(.enabled(if: folder != nil)) func renderLongMessage() async throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let nowPlaying = NowPlayingStore(service: FakeNowPlayingService(), island: IslandCoordinator())
        nowPlaying.handle(.item(NowPlaying(title: "Glass Harbor", artist: "Wren", bundleIdentifier: "com.spotify.client",
                                           isPlaying: true, duration: 199, elapsed: 15, timestamp: .now)))
        let lyrics = LyricsStore(service: FakeLyricsService(answer: .failed("test")), nowPlaying: nowPlaying)
        lyrics.start()
        for _ in 0..<100 where lyrics.status != .failed { try await Task.sleep(for: .milliseconds(10)) }
        let view = HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10).fill(Color.gray).frame(width: 56, height: 56)
            LyricsArea(lyrics: lyrics, song: "Glass Harbor · Ber", sweep: false, onSeek: { _ in })
            Spacer(minLength: 8)
            RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.9)).frame(width: 28, height: 26)
            RoundedRectangle(cornerRadius: 6).fill(Color.green).frame(width: 24, height: 24)
        }
        .padding(16)
        .frame(width: 420)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .environment(\.offscreenRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent("lyrics-message.png"))
    }
}

/// `BRIM_SNAPSHOTS=<folder> swift test --filter FavoriteStarSnapshotTests` writes favorite-star.png:
/// Favorite & Output with Apple Music (★ lit) and with Spotify (★ faded), your report 2026-09-30.
@MainActor
struct FavoriteStarSnapshotTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    private func row(player: String, modes: PlayerModes) async throws -> some View {
        let nowPlaying = NowPlayingStore(service: FakeNowPlayingService(), island: IslandCoordinator())
        nowPlaying.handle(.item(NowPlaying(title: "Glass Harbor", artist: "Wren", bundleIdentifier: player,
                                           isPlaying: true, duration: 199, elapsed: 15, timestamp: .now)))
        let store = PlayerModesStore(service: FakePlayerControls(modes), nowPlaying: nowPlaying)
        store.refresh()
        for _ in 0..<100 where store.modes == nil { try await Task.sleep(for: .milliseconds(10)) }
        let outputs = AudioOutputsStore(service: FakeOutputs())
        outputs.start()
        return TransportRow(store: nowPlaying, modes: store, large: true, sideButtons: .favoriteOutput)
            .environment(outputs)
    }

    @Test(.enabled(if: folder != nil)) func renderStars() async throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let music = try await row(player: "com.apple.Music", modes: PlayerModes(shuffle: false, repeatMode: .off, favorite: true))
        let spotify = try await row(player: "com.spotify.client", modes: PlayerModes(shuffle: true, repeatMode: .off))
        let view = VStack(alignment: .leading, spacing: 18) {
            Text("Apple Music").font(.caption).foregroundStyle(.secondary)
            music
            Text("Spotify").font(.caption).foregroundStyle(.secondary)
            spotify
        }
        .padding(20)
        .frame(width: 420)
        .background(Color.black)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .environment(\.offscreenRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent("favorite-star.png"))
    }
}

/// `BRIM_SNAPSHOTS=<folder> swift test --filter KeepAwakeRingSnapshotTests` writes keep-awake-ring.png: the coffee
/// bubble with 18 of 30 minutes left, without a length, and the coffee pill alone with a length (0.13.1).
@MainActor
struct KeepAwakeRingSnapshotTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    @Test(.enabled(if: folder != nil)) func renderRings() throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let timed = KeepAwakeStore(service: FakeKeepAwake(), island: IslandCoordinator())
        let started = Date().addingTimeInterval(-12 * 60)
        timed.now = { started }
        timed.start(minutes: 30)
        let untimed = KeepAwakeStore(service: FakeKeepAwake(), island: IslandCoordinator())
        untimed.start(minutes: nil)
        let ring = IslandMetrics.timerBubble(appearance: .black).side
        let view = HStack(spacing: 24) {
            KeepAwakeBubbleView(store: timed, edgeToEdge: true).frame(width: ring, height: ring)
            KeepAwakeBubbleView(store: untimed, edgeToEdge: true).frame(width: ring, height: ring)
            KeepAwakePillView(store: timed)
                .frame(width: 68, height: 34)
                .background(Color.black, in: Capsule())
        }
        .padding(20)
        .background(Color(white: 0.25))
        .environment(\.colorScheme, .dark)
        .environment(\.offscreenRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent("keep-awake-ring.png"))
        timed.stop()
        untimed.stop()
    }
}

/// `BRIM_SNAPSHOTS=<folder> swift test --filter SlimActivitiesMockupTests` writes slim-activities.png: three ways
/// to show Live Activities while the slim line is on (your question, 2026-09-30), over a stand-in app toolbar.
@MainActor
struct SlimActivitiesMockupTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]
    private let orange = Color.orange
    private let art = Color(red: 0.35, green: 0.55, blue: 0.95)

    /// A dark app window's top: toolbar buttons start about 8 pt below the edge.
    private func toolbar() -> some View {
        ZStack(alignment: .top) {
            Color(white: 0.13)
            HStack(spacing: 10) {
                ForEach(0..<9, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.24)).frame(width: 34, height: 22)
                }
            }
            .padding(.top, 9)
        }
        .frame(width: 440, height: 58)
    }

    private func drain(_ share: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(orange.opacity(0.3))
            Capsule().fill(orange).frame(width: width * share)
        }
        .frame(width: width, height: height)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            .frame(width: 440, alignment: .leading)
    }

    /// A · Marks on the line: keep-awake a dot on the left, the soonest countdown a draining bar on the right.
    private func marksGlass() -> some View {
        HStack(spacing: 4) {
            Circle().fill(orange).frame(width: 4, height: 4)
            Capsule().fill(art).frame(width: 120, height: 4)
            drain(0.6, width: 22, height: 4)
        }
        .padding(.top, 3)
    }

    private func marksBlack() -> some View {
        ZStack {
            UnevenRoundedRectangle(bottomLeadingRadius: 4.5, bottomTrailingRadius: 4.5).fill(Color.black)
                .frame(width: 164, height: 9)
            HStack(spacing: 5) {
                Circle().fill(orange).frame(width: 4, height: 4)
                Capsule().fill(art).frame(width: 104, height: 2.5)
                drain(0.6, width: 16, height: 2.5)
            }
        }
    }

    /// B · Small bubbles under the line's ends (reaches 10–18 pt down: over the toolbar's top).
    private func dotsGlass() -> some View {
        VStack(spacing: 3) {
            Capsule().fill(art).frame(width: 120, height: 4)
            HStack {
                Image(systemName: "cup.and.saucer.fill").font(.system(size: 6)).foregroundStyle(orange)
                    .frame(width: 10, height: 10).background(Color.black.opacity(0.85), in: Circle())
                Spacer()
                Circle().trim(from: 0, to: 0.6).stroke(orange, lineWidth: 1.5).rotationEffect(.degrees(-90))
                    .frame(width: 8, height: 8).frame(width: 10, height: 10).background(Color.black.opacity(0.85), in: Circle())
            }
            .frame(width: 130)
        }
        .padding(.top, 3)
    }

    /// C · The pill comes back while anything runs (the slim line only when music is alone).
    private func pillBack() -> some View {
        HStack(spacing: 8) {
            Image(systemName: "cup.and.saucer.fill").font(.system(size: 13)).foregroundStyle(orange)
                .frame(width: 37, height: 37).background(Color(white: 0.2), in: Circle())
            HStack {
                RoundedRectangle(cornerRadius: 5).fill(art).frame(width: 24, height: 24)
                Spacer()
                HStack(spacing: 2) { ForEach([8, 14, 10, 16, 9], id: \.self) { Capsule().fill(art).frame(width: 2.5, height: CGFloat($0)) } }
            }
            .padding(.horizontal, 5)
            .frame(width: 128, height: 34)
            .background(Color(white: 0.2), in: Capsule())
            ZStack {
                Circle().stroke(orange.opacity(0.3), lineWidth: 3)
                Circle().trim(from: 0, to: 0.6).stroke(orange, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                Text("12").font(.system(size: 11, weight: .bold)).foregroundStyle(orange)
            }
            .padding(5)
            .frame(width: 37, height: 37).background(Color(white: 0.2), in: Circle())
        }
        .padding(.top, 6)
    }

    @Test(.enabled(if: folder != nil)) func renderOptions() throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let view = VStack(alignment: .leading, spacing: 10) {
            label("A · Marks on the line (Glass, then Black): a dot for keep-awake, a draining bar for the next countdown")
            toolbar().overlay(alignment: .top) { marksGlass() }
            toolbar().overlay(alignment: .top) { marksBlack() }
            label("B · Tiny bubbles under the line: easier to see, but they reach into the toolbar")
            toolbar().overlay(alignment: .top) { dotsGlass() }
            label("C · The pill comes back while anything runs: clearest, but it covers the toolbar again")
            toolbar().overlay(alignment: .top) { pillBack() }
        }
        .padding(16)
        .background(Color(white: 0.07))
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent("slim-activities.png"))
    }
}

/// `BRIM_SNAPSHOTS=<folder> swift test --filter LongTimesSnapshotTests` writes long-times.png: the progress row for a
/// song, a 2 h 15 min video at 29:50, and one past its first hour, in the island and full-screen sizes
/// (your screenshot 2, 2026-09-30: "−1:45:14" wrapped onto two lines).
@MainActor
struct LongTimesSnapshotTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    private func item(duration: TimeInterval, elapsed: TimeInterval) -> NowPlaying {
        NowPlaying(title: "x", isPlaying: false, duration: duration, elapsed: elapsed, timestamp: .now)
    }

    @Test(.enabled(if: folder != nil)) func renderRows() throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let cases = [item(duration: 210, elapsed: 70), item(duration: 8114, elapsed: 1790), item(duration: 8104, elapsed: 3912)]
        let view = VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(cases.enumerated()), id: \.offset) { _, item in
                ProgressRow(item: item).frame(width: 388)
            }
            ForEach(Array(cases.enumerated()), id: \.offset) { _, item in
                ProgressRow(item: item, large: true).frame(width: 400)
            }
        }
        .padding(16)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .environment(\.offscreenRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent(ProcessInfo.processInfo.environment["BRIM_SNAPSHOT_NAME"] ?? "long-times.png"))
    }
}

/// `BRIM_SNAPSHOTS=<folder> swift test --filter ArtInsetSnapshotTests` writes art-inset.png: the kept music pill in
/// Glass (on a stand-in capsule: glass can't render offscreen) and Black, 4× (your screenshot 5, 2026-09-30).
@MainActor
struct ArtInsetSnapshotTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    private func cover() -> Data {
        let image = NSImage(size: NSSize(width: 60, height: 60), flipped: false) { rect in
            NSGradient(colors: [.systemIndigo, .systemTeal])?.draw(in: rect, angle: 45)
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test(.enabled(if: folder != nil)) func renderPills() throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let nowPlaying = NowPlayingStore(service: FakeNowPlayingService(), island: IslandCoordinator())
        nowPlaying.handle(.item(NowPlaying(title: "x", artist: "y", isPlaying: true, artwork: cover())))
        let glass = IslandMetrics.pillSize(appearance: .liquidGlass), black = IslandMetrics.pillSize(appearance: .black)
        let view = HStack(spacing: 24) {
            KeptMusicView(store: nowPlaying, appearance: .liquidGlass)
                .frame(width: glass.width, height: glass.height)
                .background(Color(white: 0.24), in: Capsule())
            KeptMusicView(store: nowPlaying, appearance: .black)
                .frame(width: black.width, height: black.height)
                .background(Color.black, in: UnevenRoundedRectangle(bottomLeadingRadius: black.height / 2,
                                                                     bottomTrailingRadius: black.height / 2))
        }
        .padding(12)
        .background(Color(white: 0.6))
        .environment(\.colorScheme, .dark)
        .environment(\.offscreenRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 4
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent(ProcessInfo.processInfo.environment["BRIM_SNAPSHOT_NAME"] ?? "art-inset.png"))
    }
}

/// `BRIM_SNAPSHOTS=<folder> swift test --filter SlimMarksSnapshotTests` writes slim-marks.png: the real slim line with
/// its Live Activity marks (keep-awake dot, a timer's draining bar), Glass and Black, with and without music.
@MainActor
struct SlimMarksSnapshotTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    @Test(.enabled(if: folder != nil)) func renderMarks() throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let island = IslandCoordinator()
        let timer = TimerStore(island: island, alarm: FakeAlarm(), defaults: UserDefaults(suiteName: testSuiteName("brim.tests.slim"))!)
        timer.start(minutes: 25)
        let marks = IslandSides.slimMarks(timer: timer, calendar: nil, keepAwake: true)
        func row(_ look: IslandAppearance, music: Bool) -> some View {
            let size = IslandMetrics.size(for: .slim, appearance: look,
                                          slim: IslandMetrics.SlimParts(line: music, dot: marks.left, bar: marks.right != nil))
            return SlimLineView(appearance: look, tint: TintColor(hue: 0.6, saturation: 0.7, brightness: 0.9), isPlaying: true,
                                showsLine: music, marks: marks, timer: timer, calendar: nil)
                .frame(width: size.width, height: size.height)
                .background(look == .black ? Color.black : Color.clear,
                            in: UnevenRoundedRectangle(bottomLeadingRadius: size.height / 2, bottomTrailingRadius: size.height / 2))
                .padding(.top, IslandMetrics.topGap(for: .slim, appearance: look))
                .frame(width: 300, height: 30, alignment: .top)
                .background(Color(white: 0.13))
        }
        let view = VStack(spacing: 8) {
            row(.liquidGlass, music: true)
            row(.black, music: true)
            row(.liquidGlass, music: false)
            row(.black, music: false)
        }
        .padding(10)
        .background(Color(white: 0.07))
        .environment(\.colorScheme, .dark)
        .environment(\.offscreenRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 4
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent("slim-marks.png"))
        timer.cancelAll()
    }
}

/// `BRIM_SNAPSHOTS=<folder> swift test --filter SidePagingSnapshotTests` writes side-paging.png: the row and its dots
/// at five points of a swipe from Shuffle & Repeat to Favorite & Output (your pick, 2026-11-16: it follows your
/// fingers), plus a pull past the edge.
@MainActor
struct SidePagingSnapshotTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    @Test(.enabled(if: folder != nil)) func renderSwipe() async throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let nowPlaying = NowPlayingStore(service: FakeNowPlayingService(), island: IslandCoordinator())
        nowPlaying.handle(.item(NowPlaying(title: "Glass Harbor", artist: "Wren", bundleIdentifier: "com.apple.Music",
                                           isPlaying: true, duration: 199, elapsed: 15, timestamp: .now)))
        let store = PlayerModesStore(service: FakePlayerControls(PlayerModes(shuffle: true, repeatMode: .all, favorite: true)),
                                     nowPlaying: nowPlaying)
        store.refresh()
        for _ in 0..<100 where store.modes == nil { try await Task.sleep(for: .milliseconds(10)) }
        let outputs = AudioOutputsStore(service: FakeOutputs())
        outputs.start()
        let positions: [Double] = [SidePaging.position(page: 0, fingerDX: 60), 0, 0.25, 0.5, 0.75, 1]
        let view = VStack(alignment: .leading, spacing: 14) {
            ForEach(positions.indices, id: \.self) { i in
                HStack(spacing: 14) {
                    Text(String(format: "%.2f", positions[i])).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    VStack(spacing: 6) {
                        TransportRow(store: nowPlaying, modes: store, sideButtons: positions[i] >= 0.5 ? .favoriteOutput : .shuffleRepeat,
                                     pagePosition: positions[i])
                        SidePageDots(selected: positions[i] >= 0.5 ? .favoriteOutput : .shuffleRepeat, position: positions[i]) { _ in }
                    }
                }
            }
        }
        .environment(outputs)
        .padding(20)
        .frame(width: 400)
        .background(Color.black)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .environment(\.offscreenRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent("side-paging.png"))
    }
}

/// `BRIM_SNAPSHOTS=<folder> swift test --filter LyricsSyncBarSnapshotTests` writes lyrics-sync-bar.png: the bar for
/// fixing lyrics timing, island size and full-screen size (your pick, 2026-11-16).
@MainActor
struct LyricsSyncBarSnapshotTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    @Test(.enabled(if: folder != nil)) func renderBar() throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let nowPlaying = NowPlayingStore(service: FakeNowPlayingService(), island: IslandCoordinator())
        let lyrics = LyricsStore(service: FakeLyricsService(answer: .notFound), nowPlaying: nowPlaying)
        let view = VStack(spacing: 24) {
            LyricsSyncBar(lyrics: lyrics).frame(width: 388)
            LyricsSyncBar(lyrics: lyrics, large: true).frame(width: 520)
        }
        .padding(24)
        .background(Color(red: 0.25, green: 0.18, blue: 0.14))
        .environment(\.colorScheme, .dark)
        .environment(\.offscreenRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent("lyrics-sync-bar.png"))
    }
}

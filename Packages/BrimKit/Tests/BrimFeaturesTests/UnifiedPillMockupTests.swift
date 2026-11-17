import AppKit
import SwiftUI
import Testing
@testable import BrimCore
@testable import BrimFeatures

/// The unified pill (docs/05-interaction-model.md, 2026-09-30), drawn with Brim's real views at the new sizes:
/// resting (music + timer ring), volume inside the pill, every glance at 320, and the open island's two pages
/// with two styles of page switch. `BRIM_SNAPSHOTS=<folder> swift test --filter UnifiedPillMockupTests`
/// writes unified-1-pill.png and unified-2-open.png.
@MainActor
struct UnifiedPillMockupTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    @Test(.enabled(if: folder != nil)) func renderUnifiedPill() async throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let kit = try await Kit.make()
        let glass = IslandAppearance.liquidGlass
        let pill = IslandMetrics.pillSize(appearance: glass)
        let blackPill = IslandMetrics.pillSize(appearance: .black)
        let glance = CGSize(width: 320, height: pill.height)

        let sheet1 = VStack(alignment: .leading, spacing: 20) {
            row("Resting · music, with a running timer's ring beside it", [
                Top(label: "Liquid Glass · 128 × 34 + ring") {
                    Resting(appearance: glass, kit: kit)
                },
                Top(label: "Black · 185 × 32 + ring") {
                    Resting(appearance: .black, kit: kit)
                },
            ])
            row("Volume and brightness inside the pill · same shape, the content swaps", [
                Top(label: "Volume · Glass · 128 × 34") {
                    Shape(appearance: glass, size: pill) {
                        LevelHUDView(volume: VolumeState(level: 0.62, isMuted: false), style: .standard, appearance: glass)
                    }
                },
                Top(label: "Volume · Black · 185 × 32") {
                    Shape(appearance: .black, size: blackPill) {
                        LevelHUDView(volume: VolumeState(level: 0.62, isMuted: false), style: .standard, appearance: .black)
                    }
                },
                Top(label: "Brightness · Glass") {
                    Shape(appearance: glass, size: pill) {
                        LevelHUDView(brightness: BrightnessState(level: 0.35), style: .standard, appearance: glass)
                    }
                },
            ])
            row("Every glance · one size, 320 × 34 · one at a time", [
                Top(label: "Song change") { Shape(appearance: glass, size: glance) { CompactMediaView(store: kit.nowPlaying) } },
                Top(label: "Battery") { Shape(appearance: glass, size: glance) { BatteryNoticeView(store: kit.battery) } },
                Top(label: "AirPods") { Shape(appearance: glass, size: glance) { HeadphonesNoticeView(store: kit.headphones) } },
            ])
            row("", [
                Top(label: "Calendar (a long title glides once)") { Shape(appearance: glass, size: glance) { CalendarReminderView(store: kit.calendar) } },
                Top(label: "Timer notice") { Shape(appearance: glass, size: glance) { TimerNoticeView(timer: kit.timer) } },
                Top(label: "Time's up") { Shape(appearance: glass, size: glance) { TimerDoneView(timer: kit.ended) } },
            ])
        }
        try save(sheet1, to: out.appendingPathComponent("unified-1-pill.png"))

        let media = CGSize(width: 420, height: 170)
        let today = CGSize(width: 420, height: 150)
        let sheet2 = VStack(alignment: .leading, spacing: 20) {
            row("Page switch A · labels on top (+28 pt)", [
                Top(label: "Now Playing · 420 × 198", height: 230) {
                    Shape(appearance: glass, size: CGSize(width: 420, height: media.height + 28), radius: 24) {
                        VStack(spacing: 0) { LabelSwitch(selected: 0).padding(.top, 10); kit.mediaPage }
                    }
                },
                Top(label: "Today · 420 × 178", height: 230) {
                    Shape(appearance: glass, size: CGSize(width: 420, height: today.height + 28), radius: 24) {
                        VStack(spacing: 0) { LabelSwitch(selected: 1).padding(.top, 10); kit.todayPage }
                    }
                },
            ])
            row("Page switch B · two dots at the bottom (no extra height)", [
                Top(label: "Now Playing · 420 × 170", height: 210) {
                    Shape(appearance: glass, size: media, radius: 24) {
                        kit.mediaPage.overlay(alignment: .bottom) { Dots(selected: 0).padding(.bottom, 5) }
                    }
                },
                Top(label: "Today · 420 × 150", height: 210) {
                    Shape(appearance: glass, size: today, radius: 24) {
                        kit.todayPage.overlay(alignment: .bottom) { Dots(selected: 1).padding(.bottom, 5) }
                    }
                },
            ])
            row("An event while it's open · a thin banner inside, the island stays open", [
                Top(label: "AirPods connect while Today is open: the top row swaps for 3 s", height: 210) {
                    Shape(appearance: glass, size: today, radius: 24) {
                        VStack(alignment: .leading, spacing: 10) {
                            HeadphonesNoticeView(store: kit.headphones)
                                .padding(.horizontal, -12)
                                .frame(height: 30)
                                .padding(.horizontal, 10)
                                .background(Color.primary.opacity(0.1), in: Capsule())
                                .frame(height: 44)
                            EventRow(store: kit.calendar)
                            Text("Timers").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                    }
                },
            ])
        }
        try save(sheet2, to: out.appendingPathComponent("unified-2-open.png"))
    }

    private func row(_ title: String, _ tiles: [Top]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty { Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white) }
            HStack(alignment: .top, spacing: 16) { ForEach(tiles.indices, id: \.self) { tiles[$0] } }
        }
    }

    private func save(_ sheet: some View, to url: URL) throws {
        let view = sheet
            .padding(28)
            .background(Color(white: 0.09))
            .environment(\.offscreenRender, true)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}

/// Real stores with made-up content, so the real views have something to show.
@MainActor
private struct Kit {
    let nowPlaying: NowPlayingStore
    let battery: BatteryStore
    let headphones: HeadphonesStore
    let calendar: CalendarStore
    let timer: TimerStore
    let ended: TimerStore
    let presets: TimerStore
    let mediaPage: AnyView
    let todayPage: AnyView

    static func make() async throws -> Kit {
        let island = IslandCoordinator()
        let settings = IslandSettings(defaults: UserDefaults(suiteName: testSuiteName("brim.snapshots"))!)
        let nowPlaying = NowPlayingStore(service: FakeNowPlayingService(), island: island)
        var song = NowPlaying(title: "maybe i was wrong about you", artist: "Nora Vale", bundleIdentifier: "com.spotify.client",
                              isPlaying: true, duration: 196, elapsed: 51, timestamp: .now)
        song.artwork = try gradientPNG()
        nowPlaying.handle(.item(song))
        let lyrics = LyricsStore(service: FakeLyricsService(answer: .notFound), nowPlaying: nowPlaying)
        let modes = PlayerModesStore(service: FakePlayerControls(PlayerModes(shuffle: true, repeatMode: .off)), nowPlaying: nowPlaying)
        modes.refresh()
        for _ in 0..<100 where modes.modes == nil { try await Task.sleep(for: .milliseconds(10)) }

        let battery = BatteryStore(service: FakeBattery(), island: island)
        battery.handle(BatteryState(level: 0.62, power: .battery, lowPowerMode: false))
        battery.handle(BatteryState(level: 0.62, power: .charging, lowPowerMode: false))  // under 80%: says so at once
        let headphones = HeadphonesStore(service: FakeHeadphones(), island: island)
        headphones.handle(HeadphonesConnection(battery: HeadphonesBattery(name: "AirPods Pro", left: 100, right: 96, caseLevel: 88)))

        let calendarService = FakeCalendar()
        let start = Date().addingTimeInterval(36 * 60)
        calendarService.events = [CalendarEvent(id: "a", title: "Design Review · Weekly", start: start,
                                                end: start.addingTimeInterval(3600),
                                                meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"))]
        let calendar = CalendarStore(service: calendarService, island: island)
        await calendar.setEnabled(true)
        calendar.remind(about: CalendarEvent(id: "b", title: "Design Review · Weekly", start: Date().addingTimeInterval(300),
                                             end: Date().addingTimeInterval(3900),
                                             meetingURL: URL(string: "https://meet.google.com/abc-defg-hij")), lateBy: 0)

        let name = testSuiteName("brim.snapshots")
        let timer = TimerStore(island: IslandCoordinator(), alarm: QuietAlarm(), defaults: UserDefaults(suiteName: name)!)
        timer.start(minutes: 25)
        let endedName = testSuiteName("brim.snapshots")
        let t0 = Date()
        let first = TimerStore(island: IslandCoordinator(), alarm: QuietAlarm(), defaults: UserDefaults(suiteName: endedName)!)
        first.now = { t0 }
        first.start(minutes: 25)
        let ended = TimerStore(island: IslandCoordinator(), alarm: QuietAlarm(), defaults: UserDefaults(suiteName: endedName)!)
        ended.now = { t0.addingTimeInterval(25 * 60 + 1) }
        ended.start()

        let presets = TimerStore(island: IslandCoordinator(), alarm: QuietAlarm(),
                                 defaults: UserDefaults(suiteName: testSuiteName("brim.snapshots"))!)
        // A stand-in: drawn offscreen, the real Now Playing view greys out the whole image (an AppKit-backed
        // part in it; on screen it's fine). Same layout, sizes and fonts.
        _ = (lyrics, modes, settings)
        let media = AnyView(MediaStandIn())
        let today = AnyView(CalendarTabView(actions: .none, calendar: calendar, showsEvent: true))
        return Kit(nowPlaying: nowPlaying, battery: battery, headphones: headphones, calendar: calendar, timer: timer,
                   ended: ended, presets: presets, mediaPage: media, todayPage: today)
    }

    private static func gradientPNG() throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: NSColor(srgbRed: 0.93, green: 0.42, blue: 0.62, alpha: 1),
                   ending: NSColor(srgbRed: 0.36, green: 0.24, blue: 0.72, alpha: 1))?
            .draw(in: NSRect(x: 0, y: 0, width: 64, height: 64), angle: -45)
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.representation(using: .png, properties: [:]))
    }
}

private final class QuietAlarm: TimerAlarm {
    func prepare() {}
    func ring(title: String, body: String) {}
    func silence() {}
}

/// The top of a screen with one island on it.
private struct Top: View {
    let label: String
    var height: CGFloat = 70
    let content: AnyView

    init(label: String, height: CGFloat = 70, @ViewBuilder content: () -> some View) {
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
            .frame(width: 460, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
        }
    }
}

/// One island shape with the island's real surface: floating glass, or a notch hanging from the top edge.
private struct Shape: View {
    let appearance: IslandAppearance
    let size: CGSize
    var radius: CGFloat?
    let content: AnyView

    init(appearance: IslandAppearance, size: CGSize, radius: CGFloat? = nil, @ViewBuilder content: () -> some View) {
        self.appearance = appearance
        self.size = size
        self.radius = radius
        self.content = AnyView(content())
    }

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .modifier(IslandSurfaceStyle(appearance: appearance, cornerRadius: radius ?? size.height / 2,
                                         shoulder: appearance == .black ? 6 : 0))
            .padding(.top, appearance == .black ? 0 : 6)
    }
}

/// The music pill with the ring bubble beside it, placed as the island will place them.
private struct Resting: View {
    let appearance: IslandAppearance
    let kit: Kit

    var body: some View {
        let pill = IslandMetrics.pillSize(appearance: appearance)
        let bubble = IslandMetrics.timerBubble(appearance: appearance)
        ZStack(alignment: .top) {
            Group {
                if appearance == .black {
                    TimerBubbleView(timer: kit.timer, edgeToEdge: true).frame(width: bubble.side, height: bubble.side)
                } else {
                    TimerBubbleView(timer: kit.timer)
                        .frame(width: bubble.side, height: bubble.side)
                        .modifier(IslandSurfaceStyle(appearance: appearance, cornerRadius: bubble.side / 2, shoulder: 0))
                }
            }
                .padding(.top, bubble.top)
                .offset(x: bubble.centreOffset)
            Shape(appearance: appearance, size: pill) { KeptMusicView(store: kit.nowPlaying, appearance: appearance) }
        }
    }
}

/// Switch A: "Now Playing | Today" at the top of the open island.
private struct LabelSwitch: View {
    let selected: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(["Now Playing", "Today"].enumerated()), id: \.offset) { index, title in
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(index == selected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 20)
                    .background(index == selected ? Color.primary.opacity(0.14) : .clear, in: Capsule())
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

/// Switch B: two small dots at the bottom, like an iPhone widget stack.
private struct Dots: View {
    let selected: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { index in
                Circle().fill(Color.primary.opacity(index == selected ? 0.9 : 0.3)).frame(width: 6, height: 6)
            }
        }
    }
}

/// Now Playing as the island draws it (ExpandedMediaView: 56 pt art, title and artist, lyrics button and app
/// icon, progress with times, and the transport row with shuffle and repeat).
private struct MediaStandIn: View {
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
                Spacer(minLength: 8)
                Image(systemName: "quote.bubble.fill").font(.system(size: 13))
                    .frame(width: 28, height: 26).background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.85)).frame(width: 22, height: 22)
            }
            HStack(spacing: 10) {
                Text("0:51").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                Capsule().fill(Color.primary.opacity(0.2)).frame(height: 4)
                    .overlay(alignment: .leading) { Capsule().fill(Color.primary.opacity(0.8)).frame(width: 80, height: 4) }
                Text("-2:25").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 24) {
                Image(systemName: "shuffle").font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 26).background(Color.primary.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                Image(systemName: "backward.fill").font(.system(size: 16, weight: .semibold))
                Image(systemName: "pause.fill").font(.system(size: 22, weight: .semibold))
                Image(systemName: "forward.fill").font(.system(size: 16, weight: .semibold))
                Image(systemName: "repeat").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 26)
            }
        }
        .padding(16)
    }
}

/// Black appearance, your notes (2026-09-30): the timer ring and the volume HUD float, not hanging from the
/// edge. `BRIM_SNAPSHOTS=<folder> swift test --filter BlackDetachedMockupTests` writes black-detached.png.
@MainActor
struct BlackDetachedMockupTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    @Test(.enabled(if: folder != nil)) func renderBlackDetached() async throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let kit = try await Kit.make()
        let notch = IslandMetrics.pillSize(appearance: .black)          // 185 × 32, hanging from the edge
        let floating = CGSize(width: notch.width, height: notch.height)  // same size, floating 6 pt down
        let volume = VolumeState(level: 0.62, isMuted: false)
        let sheet = VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Timer ring, detached: a floating circle beside the notch, clear of the top edge").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                HStack(spacing: 16) {
                    Top(label: "Ring 30 pt, 4 pt below the edge, 12 pt from the notch") { DetachedRing(kit: kit, notch: notch) }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Volume in Black: two ways to detach it").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                HStack(spacing: 16) {
                    Top(label: "1 · The notch lets go of the edge and floats for 1.5 s, then hangs again") {
                        FloatingBlack(size: floating) {
                            LevelHUDView(volume: volume, style: .standard, appearance: .black)
                        }
                    }
                    Top(label: "2 · The notch stays; the HUD floats just below it", height: 90) {
                        VStack(spacing: 6) {
                            BlackNotch(size: notch) { KeptMusicView(store: kit.nowPlaying, appearance: .black) }
                            FloatingBlack(size: CGSize(width: 128, height: 30), top: 0) {
                                LevelHUDView(volume: volume, style: .standard, appearance: .black)
                            }
                        }
                    }
                }
            }
        }
        let view = sheet
            .padding(28)
            .background(Color(white: 0.09))
            .environment(\.offscreenRender, true)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent("black-detached.png"))
    }
}

private struct BlackNotch: View {
    let size: CGSize
    let content: AnyView
    init(size: CGSize, @ViewBuilder content: () -> some View) {
        self.size = size
        self.content = AnyView(content())
    }
    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .modifier(IslandSurfaceStyle(appearance: .black, cornerRadius: size.height / 2, shoulder: 6))
    }
}

/// A black capsule that floats like the glass one: rounded all round, a gap above it.
private struct FloatingBlack: View {
    let size: CGSize
    var top: CGFloat = 6
    let content: AnyView
    init(size: CGSize, top: CGFloat = 6, @ViewBuilder content: () -> some View) {
        self.size = size
        self.top = top
        self.content = AnyView(content())
    }
    var body: some View {
        content
            .environment(\.colorScheme, .dark)
            .frame(width: size.width, height: size.height)
            .background(Color.black, in: Capsule())
            .clipShape(Capsule())
            .padding(.top, top)
    }
}

private struct DetachedRing: View {
    let kit: Kit
    let notch: CGSize
    var body: some View {
        let side: CGFloat = 30
        ZStack(alignment: .top) {
            TimerBubbleView(timer: kit.timer)
                .frame(width: side, height: side)
                .background(Color.black, in: Circle())
                .padding(.top, 4)
                .offset(x: notch.width / 2 + 6 + 12 + side / 2)
            BlackNotch(size: notch) { KeptMusicView(store: kit.nowPlaying, appearance: .black) }
        }
    }
}

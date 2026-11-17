import AppKit
import SwiftUI
import Testing
@testable import BrimCore
@testable import BrimFeatures

/// F9 mockups (2026-09-30): the timer beside the music pill (two bubble styles), alone, open, and ending.
/// `BRIM_SNAPSHOTS=<folder> swift test --filter TimerMockupTests` writes timer-mockups.png.
@MainActor
struct TimerMockupTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    @Test(.enabled(if: folder != nil)) func renderTimerMockups() throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let sheet = VStack(alignment: .leading, spacing: 22) {
            row("Timer beside the music · two-finger swipe shows or hides it · bubble 1.1 × pill height, 8 pt gap", [
                TopOfScreen(label: "A · Ring with minutes · Glass") { PillWithBubble(glass: true) { RingBubble(minutes: 24, share: 0.96) } },
                TopOfScreen(label: "A · Ring with minutes · Black") { PillWithBubble(glass: false) { RingBubble(minutes: 24, share: 0.96) } },
                TopOfScreen(label: "B · Time · Glass") { PillWithBubble(glass: true, bubbleWidth: 66) { TimeBubble(text: "24:13") } },
                TopOfScreen(label: "B · Time · Black") { PillWithBubble(glass: false, bubbleWidth: 66) { TimeBubble(text: "24:13") } },
            ])
            row("No music: the timer takes the centre (same size as the music pill)", [
                TopOfScreen(label: "Glass · 128 × 34") { Island(glass: true, size: CGSize(width: 128, height: 34)) { TimerPill() } },
                TopOfScreen(label: "Black · 185 × 32") { Island(glass: false, size: CGSize(width: 185, height: 32)) { TimerPill() } },
                TopOfScreen(label: "5 and 1 min left: 3 s, then back") { Island(glass: true, size: CGSize(width: 280, height: 34)) { LeftNotice() } },
                TopOfScreen(label: "Time's up: stays until you stop it (30 s max) + sound") { Island(glass: true, size: CGSize(width: 320, height: 34)) { DoneAlert() } },
            ])
            row("Open island while it runs (nothing playing) · the presets row becomes the timer", [
                TopOfScreen(label: "Liquid Glass · 420 × 150", height: 190) { Island(glass: true, size: CGSize(width: 420, height: 150), radius: 24) { OpenRunning() } },
                TopOfScreen(label: "Black", height: 190) { Island(glass: false, size: CGSize(width: 420, height: 150), radius: 24) { OpenRunning() } },
            ])
        }
        .padding(28)
        .background(Color(white: 0.09))
        .environment(\.offscreenRender, true)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent("timer-mockups.png"))
    }

    private func row(_ title: String, _ tiles: [TopOfScreen]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            HStack(alignment: .top, spacing: 16) { ForEach(tiles.indices, id: \.self) { tiles[$0] } }
        }
    }
}

private let timerOrange = Color.orange

/// A screen's top edge with something on it.
private struct TopOfScreen: View {
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

/// One island shape: floating glass, or a black notch hanging from the top edge.
private struct Island: View {
    let glass: Bool
    let size: CGSize
    var radius: CGFloat?
    let content: AnyView

    init(glass: Bool, size: CGSize, radius: CGFloat? = nil, @ViewBuilder content: () -> some View) {
        self.glass = glass
        self.size = size
        self.radius = radius
        self.content = AnyView(content())
    }

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .modifier(IslandSurfaceStyle(appearance: glass ? .liquidGlass : .black, cornerRadius: radius ?? size.height / 2,
                                         shoulder: glass ? 0 : 6))
            .padding(.top, glass ? 6 : 0)
    }
}

/// The kept music pill (your picks: Glass 128 × 34, Black 185 × 32) with the timer bubble to its right.
/// The pill stays centred; the bubble sits beside it, like the iPhone's second activity.
private struct PillWithBubble: View {
    let glass: Bool
    var bubbleWidth: CGFloat?
    let bubble: AnyView

    init(glass: Bool, bubbleWidth: CGFloat? = nil, @ViewBuilder bubble: () -> some View) {
        self.glass = glass
        self.bubbleWidth = bubbleWidth
        self.bubble = AnyView(bubble())
    }

    var body: some View {
        let pill = glass ? CGSize(width: 128, height: 34) : CGSize(width: 185, height: 32)
        let side = (pill.height * 1.1).rounded()
        // Black: 12 pt from the notch's flared corner, so the bubble never reads as part of the notch.
        let gap: CGFloat = glass ? 8 : 12
        let width = bubbleWidth ?? side
        ZStack(alignment: .top) {
            Island(glass: glass, size: pill) { MusicPill(height: pill.height, glass: glass) }
            // The bubble floats, in both looks: a second notch would look like a hardware fault.
            bubble
                .frame(width: width, height: side)
                .modifier(IslandSurfaceStyle(appearance: glass ? .liquidGlass : .black, cornerRadius: side / 2, shoulder: 0))
                .padding(.top, glass ? 6 - (side - pill.height) / 2 : 1)
                .offset(x: pill.width / 2 + (glass ? 0 : 6) + gap + width / 2)
        }
    }
}

private struct MusicPill: View {
    let height: CGFloat
    let glass: Bool
    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: height - 10, height: height - 10)
            Spacer(minLength: 4)
            WaveformView(isPlaying: true, tint: TintColor(hue: 0.9, saturation: 0.55, brightness: 0.95))
        }
        .padding(.horizontal, glass ? 5 : 8)
    }
}

/// A: an orange ring that empties as time runs out, with the minutes left inside.
private struct RingBubble: View {
    let minutes: Int
    let share: Double
    var body: some View {
        ZStack {
            Circle().stroke(timerOrange.opacity(0.25), lineWidth: 3)
            Circle().trim(from: 0, to: share).stroke(timerOrange, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(minutes)").font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(timerOrange)
        }
        .padding(5)
    }
}

/// B: the time itself, in orange.
private struct TimeBubble: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(timerOrange)
    }
}

private struct TimerPill: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer").font(.system(size: 13, weight: .semibold)).foregroundStyle(timerOrange)
            Text("24:13").font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(timerOrange)
        }
    }
}

private struct LeftNotice: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer").font(.system(size: 13, weight: .semibold)).foregroundStyle(timerOrange)
            Text("5 min left").font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("25-min timer").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
    }
}

private struct DoneAlert: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer").font(.system(size: 13, weight: .semibold)).foregroundStyle(timerOrange)
            Text("Time's up").font(.system(size: 13, weight: .semibold))
            Text("· 25 min").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            Text("Stop").font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).frame(height: 22)
                .background(timerOrange, in: Capsule()).foregroundStyle(.white)
        }
        .padding(.leading, 14).padding(.trailing, 6)
    }
}

/// Layout A (your pick) with the presets row replaced by the running timer and its controls.
private struct OpenRunning: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("15:24").font(.system(size: 22, weight: .semibold).monospacedDigit())
                    Text("Wednesday, 30 September").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "gearshape.fill").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(red: 0.25, green: 0.55, blue: 1)).frame(width: 3, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Design Review · Weekly").font(.system(size: 13, weight: .semibold))
                    Text("16:00 · in 36 min").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Image(systemName: "timer").font(.system(size: 13, weight: .semibold)).foregroundStyle(timerOrange)
                Text("24:13").font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(timerOrange)
                Text("of 25 min").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                ForEach(["+1 min", "Pause"], id: \.self) { label in
                    Text(label).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(Color.primary.opacity(0.12), in: Capsule())
                }
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24).background(Color.primary.opacity(0.12), in: Circle())
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

/// The real timer views (not mockups), at real size, as your 100-second test showed them.
/// `BRIM_SNAPSHOTS=<folder> swift test --filter TimerRealViewTests` writes timer-real.png.
@MainActor
struct TimerRealViewTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    @Test(.enabled(if: folder != nil)) func renderRealTimerViews() throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let name = testSuiteName("brim.snapshots")
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let t0 = Date()
        let first = TimerStore(island: IslandCoordinator(), alarm: SilentAlarm(), defaults: defaults)
        first.now = { t0 }
        first.start(length: 100)
        let done = TimerStore(island: IslandCoordinator(), alarm: SilentAlarm(), defaults: defaults)
        done.now = { t0.addingTimeInterval(101) }
        done.start()
        let running = TimerStore(island: IslandCoordinator(), alarm: SilentAlarm(), defaults: UserDefaults(suiteName: name + ".2")!)
        running.start(length: 100)
        let sheet = VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                real("Time's up · Glass · 320 × 34", glass: true, width: 320) { TimerDoneView(timer: done) }
                real("Time's up · Black · 320 × 32", glass: false, width: 320) { TimerDoneView(timer: done) }
            }
            HStack(spacing: 16) {
                real("1 min left · Glass · 280 × 34", glass: true, width: 280) { TimerNoticeView(timer: running) }
                real("Timer alone · Glass · 128 × 34", glass: true, width: 128) { TimerPillView(timer: running) }
            }
        }
        .padding(28)
        .background(Color(white: 0.09))
        .environment(\.offscreenRender, true)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent("timer-real.png"))
    }

    private func real(_ label: String, glass: Bool, width: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        let height: CGFloat = glass ? 34 : 32
        return VStack(spacing: 8) {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.42), Color(red: 0.36, green: 0.2, blue: 0.4)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                content()
                    .frame(width: width, height: height)
                    .modifier(IslandSurfaceStyle(appearance: glass ? .liquidGlass : .black, cornerRadius: height / 2,
                                                 shoulder: glass ? 0 : 6))
                    .padding(.top, glass ? 6 : 0)
            }
            .frame(width: 400, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
        }
    }
}

private final class SilentAlarm: TimerAlarm {
    func prepare() {}
    func ring(title: String, body: String) {}
    func silence() {}
}

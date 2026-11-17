import AppKit
import SwiftUI
import Testing
@testable import BrimCore
@testable import BrimFeatures

/// F8 mockups (2026-09-30): the open island when nothing plays (time, next event, timer presets, gear)
/// in two layouts, and the 5-minute alert. Made-up event. `BRIM_SNAPSHOTS=<folder> swift test
/// --filter CalendarMockupTests` writes calendar-mockups.png.
@MainActor
struct CalendarMockupTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    @Test(.enabled(if: folder != nil)) func renderCalendarMockups() throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let event = MockEvent(title: "Design Review · Weekly", time: "16:00", countdown: "in 36 min", join: true)
        let sheet = VStack(alignment: .leading, spacing: 22) {
            row("A · Stacked: time, then the event, then timers · 420 × 150", [
                Screen(label: "Liquid Glass", size: CGSize(width: 420, height: 150), appearance: .liquidGlass) { Stacked(event: event) },
                Screen(label: "Black", size: CGSize(width: 420, height: 150), appearance: .black) { Stacked(event: event) },
                Screen(label: "Nothing else today", size: CGSize(width: 420, height: 150), appearance: .liquidGlass) { Stacked(event: nil) },
            ])
            row("B · Side by side: time left, event right, timers below · 420 × 118", [
                Screen(label: "Liquid Glass", size: CGSize(width: 420, height: 118), appearance: .liquidGlass) { SideBySide(event: event) },
                Screen(label: "Black", size: CGSize(width: 420, height: 118), appearance: .black) { SideBySide(event: event) },
                Screen(label: "Nothing else today", size: CGSize(width: 420, height: 118), appearance: .liquidGlass) { SideBySide(event: nil) },
            ])
            row("5 minutes before: the alert (6 s), same in both · 320 × pill height", [
                Screen(label: "Liquid Glass · 320 × 34", size: CGSize(width: 320, height: 34), appearance: .liquidGlass) {
                    Alert(event: MockEvent(title: "Design Review · Weekly", time: "16:00", countdown: "in 5 min", join: true))
                },
                Screen(label: "Black · 320 × 32", size: CGSize(width: 320, height: 32), appearance: .black) {
                    Alert(event: MockEvent(title: "Design Review · Weekly", time: "16:00", countdown: "in 5 min", join: true))
                },
                Screen(label: "No meeting link: no Join", size: CGSize(width: 320, height: 34), appearance: .liquidGlass) {
                    Alert(event: MockEvent(title: "Dentist", time: "16:00", countdown: "in 5 min", join: false))
                },
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
        try png.write(to: out.appendingPathComponent("calendar-mockups.png"))
    }

    private func row(_ title: String, _ screens: [Screen]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            HStack(alignment: .top, spacing: 16) { ForEach(screens.indices, id: \.self) { screens[$0] } }
        }
    }
}

private struct MockEvent {
    let title: String
    let time: String
    let countdown: String
    let join: Bool
}

private let calendarBlue = Color(red: 0.25, green: 0.55, blue: 1)

private struct Clock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("15:24").font(.system(size: 22, weight: .semibold).monospacedDigit())
            Text("Wednesday, 30 September").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

private struct JoinButton: View {
    var body: some View {
        Label("Join", systemImage: "video.fill")
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Color.green.opacity(0.9), in: Capsule())
            .foregroundStyle(.white)
    }
}

private struct TimerPresets: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer").font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
            ForEach([5, 15, 25, 45], id: \.self) { minutes in
                Text("\(minutes) min")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Color.primary.opacity(0.12), in: Capsule())
            }
        }
    }
}

private struct Gear: View {
    var body: some View {
        Image(systemName: "gearshape.fill").font(.system(size: 14)).foregroundStyle(.secondary)
    }
}

/// The event line: calendar-coloured bar, title, time and countdown; Join when there's a link.
private struct EventLine: View {
    let event: MockEvent?
    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5).fill(event == nil ? Color.secondary.opacity(0.4) : calendarBlue).frame(width: 3, height: 30)
            if let event {
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(event.time) · \(event.countdown)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if event.join { JoinButton() }
            } else {
                Text("Nothing else today").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

private struct Stacked: View {
    let event: MockEvent?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) { Clock(); Spacer(); Gear() }
            EventLine(event: event)
            TimerPresets()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

private struct SideBySide: View {
    let event: MockEvent?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                Clock().fixedSize()
                EventLine(event: event)
            }
            HStack { TimerPresets(); Spacer(); Gear() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

private struct Alert: View {
    let event: MockEvent
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(calendarBlue).frame(width: 8, height: 8)
            Text(event.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text("· \(event.countdown)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).fixedSize()
            Spacer(minLength: 4)
            if event.join {
                Text("Join").font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(Color.green.opacity(0.9), in: Capsule()).foregroundStyle(.white)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
    }
}

/// The top of a screen with the island on it, using the island's real surface.
private struct Screen: View {
    let label: String
    let size: CGSize
    let appearance: IslandAppearance
    let content: AnyView

    init(label: String, size: CGSize, appearance: IslandAppearance, @ViewBuilder content: () -> some View) {
        self.label = label
        self.size = size
        self.appearance = appearance
        self.content = AnyView(content())
    }

    var body: some View {
        let glass = appearance == .liquidGlass
        let radius: CGFloat = size.height <= 40 ? size.height / 2 : 24
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.42), Color(red: 0.36, green: 0.2, blue: 0.4)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                content
                    .frame(width: size.width, height: size.height)
                    .modifier(IslandSurfaceStyle(appearance: appearance, cornerRadius: radius, shoulder: glass ? 0 : 6))
                    .padding(.top, glass ? 6 : 0)
            }
            .frame(width: 460, height: size.height + 36)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
        }
    }
}

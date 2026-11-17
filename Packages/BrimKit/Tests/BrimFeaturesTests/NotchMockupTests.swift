import AppKit
import SwiftUI
import Testing
@testable import BrimCore
@testable import BrimFeatures

/// Notch Macs (2026-10-07, release audit): what Brim does today on a screen with a notch, and two ways to fit it. The
/// notch is drawn as a 185 × 32 black cut-out, about a 14" MacBook Pro's (the real size comes from macOS at run time:
/// `NSScreen.safeAreaInsets` and the two `auxiliaryTop…Area`s). The screen has no pixels there, so anything drawn under
/// it is lost. `BRIM_SNAPSHOTS=<folder> swift test --filter NotchMockupTests` writes notch-options.png.
@MainActor
struct NotchMockupTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    /// These are geometry fixtures, not model assumptions. A live Mac supplies the actual values through NSScreen;
    /// the fixtures exercise the layout at narrow, reference, and wide reported notch profiles.
    private static let adaptiveProfiles = [
        NotchProfile(name: "Narrow profile", notchWidth: 160, topInset: 28),
        NotchProfile(name: "Reference profile", notchWidth: 185, topInset: 32),
        NotchProfile(name: "Wide profile", notchWidth: 210, topInset: 34),
    ]

    @Test(.enabled(if: folder != nil)) func renderNotchOptions() throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let sheet = VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Brim on a MacBook with a notch").font(.system(size: 18, weight: .semibold))
                Text("The notch (the darkest black) has no pixels: whatever Brim draws there is lost.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
            }
            row("Today: the pill and the middle of every notice disappear into the notch", [
                Strip(label: "Glass pill (hidden inside)") { Shape(.glass, width: 128, height: 34, top: 6) { PillContent() } },
                Strip(label: "Black pill (exactly the notch)") { Shape(.black, width: 185, height: 32, top: 0) { PillContent() } },
                Strip(label: "A notice: its middle is lost") { Shape(.glass, width: 320, height: 34, top: 6) { NoticeContent() } },
            ])
            row("A · Around the notch: the island grows out of the notch, content on its two sides (like the iPhone)", [
                Strip(label: "Pill: art left, waveform right") {
                    Shape(.black, width: 185 + 2 * 48, height: 32, top: 0) { AroundContent() }
                },
                Strip(label: "Notice: icon left, words right") {
                    Shape(.black, width: 185 + 2 * 120, height: 32, top: 0) { AroundNotice() }
                },
                Strip(label: "Open island: starts below the notch") {
                    Shape(.black, width: 420, height: 92, top: 0) { OpenBelow(gap: 32) }
                },
            ])
            row("B · Below the notch: the island as it is today, moved down under the notch", [
                Strip(label: "Glass pill") { Shape(.glass, width: 128, height: 34, top: 32 + 6) { PillContent() } },
                Strip(label: "Notice") { Shape(.glass, width: 320, height: 34, top: 32 + 6) { NoticeContent() } },
                Strip(label: "Covers more of the window below") {
                    Shape(.glass, width: 420, height: 60, top: 32 + 6) { OpenBelow(gap: 0) }
                },
            ])
        }
        try save(sheet, to: out.appendingPathComponent("notch-options.png"))
    }

    @Test(.enabled(if: folder != nil)) func renderAdaptiveProfiles() throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let sheet = VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Brim's adaptive notch placement").font(.system(size: 18, weight: .semibold))
                Text("Each profile stands in for geometry reported by macOS. The MVP keeps the pill below the physical cutout.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
            }
            HStack(alignment: .top, spacing: 14) {
                ForEach(Self.adaptiveProfiles) { profile in
                    AdaptiveProfileStrip(profile: profile)
                }
            }
        }
        try save(sheet, to: out.appendingPathComponent("adaptive-notch-profiles.png"))
    }

    private func row(_ title: String, _ strips: [Strip]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .semibold))
            HStack(alignment: .top, spacing: 16) { ForEach(strips.indices, id: \.self) { strips[$0] } }
        }
    }

    private func save(_ sheet: some View, to url: URL) throws {
        let view = sheet.padding(28).background(Color(white: 0.09)).foregroundStyle(.white)
            .environment(\.offscreenRender, true).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let tiff = try #require(renderer.nsImage?.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}

private struct NotchProfile: Identifiable {
    let name: String
    let notchWidth: CGFloat
    let topInset: CGFloat

    var id: String { name }

    var geometry: IslandDisplayGeometry {
        IslandDisplayGeometry(screenSize: CGSize(width: 1440, height: 900), notchWidth: notchWidth,
                              topSafeInset: topInset, backingScale: 2)
    }
}

private struct AdaptiveProfileStrip: View {
    let profile: NotchProfile

    var body: some View {
        let geometry = profile.geometry
        let pill = IslandMetrics.pillSize(appearance: .black, geometry: geometry)
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(white: 0.30), Color(white: 0.22)], startPoint: .top, endPoint: .bottom)
                Shape(.black, width: pill.width, height: pill.height, top: geometry.islandTopInset) {
                    PillContent()
                }
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                    .fill(Color(white: 0.02))
                    .frame(width: profile.notchWidth, height: 32)
                    .overlay(alignment: .bottom) {
                        Text("hardware cutout").font(.system(size: 8)).foregroundStyle(.white.opacity(0.35))
                    }
            }
            .frame(width: 250, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(profile.name).font(.system(size: 12, weight: .semibold))
            Text("notch " + String(Int(profile.notchWidth)) + " · safe top " + String(Int(profile.topInset)))
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
        }
    }
}

/// The top of a notch Mac's screen (a wallpaper-ish grey, the menu bar hidden), the island, and the notch on top.
private struct Strip: View {
    let label: String
    let island: AnyView

    init(label: String, @ViewBuilder island: () -> some View) {
        self.label = label
        self.island = AnyView(island())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(white: 0.30), Color(white: 0.22)], startPoint: .top, endPoint: .bottom)
                island
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                    .fill(Color(white: 0.02))
                    .frame(width: 185, height: 32)
                    .overlay(alignment: .bottom) { Text("notch").font(.system(size: 9)).foregroundStyle(.white.opacity(0.35)) }
            }
            .frame(width: 460, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
        }
    }
}

private struct Shape: View {
    enum Look { case glass, black }
    let look: Look
    let width: CGFloat
    let height: CGFloat
    let top: CGFloat
    let content: AnyView

    init(_ look: Look, width: CGFloat, height: CGFloat, top: CGFloat, @ViewBuilder content: () -> some View) {
        self.look = look
        self.width = width
        self.height = height
        self.top = top
        self.content = AnyView(content())
    }

    var body: some View {
        content
            .frame(width: width, height: height)
            .background {
                switch look {
                case .glass: Capsule().fill(.white.opacity(0.18)).overlay(Capsule().stroke(.white.opacity(0.4), lineWidth: 0.5))
                case .black: UnevenRoundedRectangle(bottomLeadingRadius: min(16, height / 2), bottomTrailingRadius: min(16, height / 2))
                    .fill(Color.black)
                }
            }
            .padding(.top, top)
    }
}

private struct PillContent: View {
    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.orange).frame(width: 20, height: 20)
            Spacer()
            Waveform()
        }
        .padding(.horizontal, 8)
    }
}

private struct AroundContent: View {
    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.orange).frame(width: 20, height: 20)
            Spacer()
            Waveform()
        }
        .padding(.horizontal, 14)
    }
}

private struct NoticeContent: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer").foregroundStyle(Color.orange)
            Text("Time's up · Focus").font(.system(size: 12, weight: .semibold))
            Spacer()
            Text("Stop").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 8).frame(height: 20)
                .background(Color.orange, in: Capsule())
        }
        .padding(.horizontal, 12)
    }
}

private struct AroundNotice: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer").foregroundStyle(Color.orange)
            Text("Time's up").font(.system(size: 12, weight: .semibold))
            Spacer()
            Text("Stop").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 8).frame(height: 20)
                .background(Color.orange, in: Capsule())
        }
        .padding(.horizontal, 14)
    }
}

private struct OpenBelow: View {
    let gap: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            Color.clear.frame(height: gap)
            HStack(spacing: 18) {
                ForEach(["music.note", "timer", "calendar"], id: \.self) { Image(systemName: $0).font(.system(size: 13)) }
            }
            RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.15)).frame(width: 300, height: 12)
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }
}

private struct Waveform: View {
    var body: some View {
        HStack(spacing: 2) {
            ForEach([8.0, 14, 10, 16, 9], id: \.self) { RoundedRectangle(cornerRadius: 1).fill(Color.orange).frame(width: 2.5, height: $0) }
        }
    }
}

import AppKit
import SwiftUI
import Testing
@testable import BrimCore
@testable import BrimFeatures

/// Mockups for your research items 3.1 and 3.5 (2026-09-30): art + waveform only, at real notch proportions.
/// `BRIM_SNAPSHOTS=<folder> swift test --filter PillMockupTests` writes pill-mockups.png.
@MainActor
struct PillMockupTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    @Test(.enabled(if: folder != nil)) func renderPillMockups() throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        let sheet = VStack(alignment: .leading, spacing: 22) {
            row("Liquid Glass (floats 6 pt below the top edge)", [
                Tile(label: "Now · 280 × 30, with title", glass: true, size: CGSize(width: 280, height: 30), title: true),
                Tile(label: "A · 112 × 32", glass: true, size: CGSize(width: 112, height: 32)),
                Tile(label: "B · 128 × 34", glass: true, size: CGSize(width: 128, height: 34)),
                Tile(label: "C · 144 × 36", glass: true, size: CGSize(width: 144, height: 36)),
            ])
            row("Black notch (hangs from the top edge)", [
                Tile(label: "Now · 280 × 30, with title", glass: false, size: CGSize(width: 280, height: 30), title: true),
                Tile(label: "D · 185 × 32 · a real 14\" notch", glass: false, size: CGSize(width: 185, height: 32)),
                Tile(label: "E · 200 × 34", glass: false, size: CGSize(width: 200, height: 34)),
            ])
            row("Song changes: the title peeks for 3 s, then the pill shrinks back", [
                Tile(label: "Peek · Liquid Glass", glass: true, size: CGSize(width: 280, height: 32), title: true),
                Tile(label: "Peek · Black", glass: false, size: CGSize(width: 280, height: 32), title: true),
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
        try png.write(to: out.appendingPathComponent("pill-mockups.png"))
    }

    private func row(_ title: String, _ tiles: [Tile]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            HStack(alignment: .top, spacing: 16) { ForEach(tiles.indices, id: \.self) { tiles[$0] } }
        }
    }
}

/// The top of a screen with one pill on it.
private struct Tile: View {
    let label: String
    let glass: Bool
    let size: CGSize
    var title = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.42), Color(red: 0.36, green: 0.2, blue: 0.4)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                pill.padding(.top, glass ? 6 : 0)
            }
            .frame(width: 300, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
        }
    }

    @ViewBuilder private var pill: some View {
        let shoulder: CGFloat = 6
        let content = HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size.height - 10, height: size.height - 10)
            if title {
                Text("maybe i was wrong about you").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            WaveformView(isPlaying: true, tint: TintColor(hue: 0.9, saturation: 0.55, brightness: 0.95))
        }
        .padding(.horizontal, glass ? 5 : 8)
        .frame(width: size.width, height: size.height)
        if glass {
            content.brimGlass(in: Capsule())
        } else {
            content
                .padding(.horizontal, shoulder)
                .background(NotchShape(bottomRadius: size.height / 2, shoulder: shoulder).fill(.black))
        }
    }
}

import AppKit
import SwiftUI
import Testing
@testable import BrimCore
@testable import BrimFeatures

/// The AirPods notice (P-4), two looks at the real size (320 pt: 280 cut the name), with your AirPods' readings from 2026-09-30.
/// `BRIM_SNAPSHOTS=<folder> swift test --filter HeadphonesMockupTests` writes airpods-notice.png.
@MainActor
struct HeadphonesMockupTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    @Test(.enabled(if: folder != nil)) func renderNoticeMockups() throws {
        let out = URL(fileURLWithPath: try #require(Self.folder))
        for symbol in ["airpodspro", "airpodpro.left", "airpodpro.right", "airpodspro.chargingcase.wireless"] {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
        }
        let yours = HeadphonesBattery(name: "AirPods Pro", left: 100, right: 96, caseLevel: 88)
        let low = HeadphonesBattery(name: "AirPods Pro", left: 64, right: 15, caseLevel: 40)
        let sheet = VStack(alignment: .leading, spacing: 22) {
            row("A · Letters: L, R, Case", [
                NoticeTile(label: "Liquid Glass · 320 × 34", glass: true) { LabelNotice(battery: yours) },
                NoticeTile(label: "Black · 320 × 32", glass: false) { LabelNotice(battery: yours) },
                NoticeTile(label: "One bud low (red under 20%)", glass: true) { LabelNotice(battery: low) },
            ])
            row("B · Icons: left bud, right bud, case", [
                NoticeTile(label: "Liquid Glass · 320 × 34", glass: true) { IconNotice(battery: yours) },
                NoticeTile(label: "Black · 320 × 32", glass: false) { IconNotice(battery: yours) },
                NoticeTile(label: "One bud low (red under 20%)", glass: true) { IconNotice(battery: low) },
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
        try png.write(to: out.appendingPathComponent("airpods-notice.png"))
    }

    private func row(_ title: String, _ tiles: [NoticeTile]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            HStack(alignment: .top, spacing: 16) { ForEach(tiles.indices, id: \.self) { tiles[$0] } }
        }
    }
}

/// A: the notice as built (the real view).
private struct LabelNotice: View {
    let battery: HeadphonesBattery
    var body: some View {
        let store = HeadphonesStore(service: FakeHeadphones(), island: IslandCoordinator())
        store.handle(HeadphonesConnection(battery: battery))
        return HeadphonesNoticeView(store: store)
    }
}

/// B: the same, with bud and case symbols instead of letters.
private struct IconNotice: View {
    let battery: HeadphonesBattery
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: battery.symbolName).font(.system(size: 14, weight: .semibold))
            Text(battery.name ?? "Connected").font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 6)
            part("airpodpro.left", battery.left)
            part("airpodpro.right", battery.right)
            part("airpodspro.chargingcase.wireless", battery.caseLevel)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private func part(_ symbol: String, _ level: Int?) -> some View {
        if let level {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("\(level)%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            .foregroundStyle(level < 20 ? Color.red : Color.primary)
            .fixedSize()
        }
    }
}

/// The top of a screen with the notice on it.
private struct NoticeTile: View {
    let label: String
    let glass: Bool
    @ViewBuilder let notice: () -> any View

    init(label: String, glass: Bool, @ViewBuilder notice: @escaping () -> some View) {
        self.label = label
        self.glass = glass
        self.notice = notice
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.42), Color(red: 0.36, green: 0.2, blue: 0.4)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                pill.padding(.top, glass ? 6 : 0)
            }
            .frame(width: 360, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
        }
    }

    @ViewBuilder private var pill: some View {
        let height: CGFloat = glass ? 34 : 32
        let content = AnyView(notice()).frame(width: IslandMetrics.glanceWidth, height: height)
        if glass {
            content.brimGlass(in: Capsule())
        } else {
            content
                .padding(.horizontal, 6)
                .background(NotchShape(bottomRadius: height / 2, shoulder: 6).fill(.black))
        }
    }
}

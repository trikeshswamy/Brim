import AppKit
import SwiftUI
import Testing
@testable import BrimFeatures

/// The Settings sidebar icons, as built (2026-10-30). `BRIM_SNAPSHOTS=<folder> swift test --filter SettingsIconsMockup`.
@MainActor
struct SettingsIconsMockupTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BRIM_SNAPSHOTS"]

    @Test(.enabled(if: folder != nil)) func renderSidebar() throws {
        let sidebar = VStack(alignment: .leading, spacing: 14) {
            ForEach(SettingsPage.allCases, id: \.self) { page in
                HStack(spacing: 10) { page.icon; Text(page.title).font(.system(size: 13)).foregroundStyle(.white) }
            }
        }
        .padding(20).frame(width: 240, alignment: .leading).background(Color(red: 0.13, green: 0.14, blue: 0.17))
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: sidebar)
        renderer.scale = 2
        let tiff = try #require(renderer.nsImage?.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let folder = try #require(Self.folder)
        try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("settings-icons.png"))
    }
}

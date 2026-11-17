#if DEBUG
import SwiftUI

/// Debug only: the looping marquee with a long made-up title and artist at the full-screen player's sizes, on its
/// background colour, so it can be timed against Apple Music's (`--marquee-check`, 2026-10-29).
public struct MarqueeMockup: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarqueeText(trigger: "check", gap: 84, bleed: 30) {
                Text("Midnight Drive (Extended Version)").font(.system(size: 24, weight: .bold))
            }
            MarqueeText(trigger: "check", gap: 64, bleed: 22) {
                Text("The Night Shift — Paper Lanterns: Season 2 (Original Soundtrack)").font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 400, alignment: .leading)
        .padding(.horizontal, 40).padding(.vertical, 24)
        .background(Color(red: 0.45, green: 0.25, blue: 0.16))
        .environment(\.colorScheme, .dark)
    }
}
#endif

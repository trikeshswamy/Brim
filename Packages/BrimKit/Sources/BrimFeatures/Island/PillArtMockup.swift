#if DEBUG
import SwiftUI
import BrimCore

/// Debug only: the kept pill with its artwork at three sizes, in both looks, drawn by the real views, for a
/// side-by-side pick (2026-10-01: your reference image uses ~53% of the pill's height for the artwork, Brim 71%).
/// The app's `--pill-mockup <dir>` shows it in a corner window and captures it.
public struct PillArtMockup: View {
    let store: NowPlayingStore

    public init(store: NowPlayingStore) { self.store = store }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(IslandAppearance.allCases, id: \.self) { look in
                let pill = IslandMetrics.pillSize(appearance: look)
                let now = IslandMetrics.pillArtSize(appearance: look)
                HStack(alignment: .top, spacing: 36) {
                    ForEach(Self.sizes(for: pill.height), id: \.self) { art in
                        VStack(spacing: 10) {
                            KeptMusicView(store: store, appearance: look, artSize: art)
                                .frame(width: pill.width, height: pill.height)
                                .islandSurface(look, for: .compact(.keptMusic))
                            Text(Self.label(art: art, height: pill.height, now: now))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 200)
                    }
                }
            }
        }
        .padding(24)
    }

    /// The 2026-10-01 choices: the old size (height − 10), ~59% (your pick), ~53% (your reference): 24 / 20 / 18 pt
    /// in Glass, 22 / 19 / 17 in Black.
    static func sizes(for height: CGFloat) -> [CGFloat] {
        [height - 10, (height * 0.59).rounded(), (height * 0.53).rounded()]
    }

    static func label(art: CGFloat, height: CGFloat, now: CGFloat) -> String {
        let share = Int((art / height * 100).rounded())
        return "\(Int(art)) pt · \(share)%" + (art == now ? " (now)" : "")
    }
}
#endif

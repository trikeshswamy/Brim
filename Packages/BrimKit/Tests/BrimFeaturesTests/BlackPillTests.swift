import Testing
@testable import BrimCore
@testable import BrimFeatures

/// Black Pill (your pick, 2026-10-29): Liquid Glass's floating pill, in solid black.
@MainActor
struct BlackPillTests {
    @Test func floatsLikeGlassButIsSolidBlack() {
        #expect(IslandMetrics.pillSize(appearance: .blackPill) == IslandMetrics.pillSize(appearance: .liquidGlass))
        #expect(IslandMetrics.topGap(for: .compact(.keptMusic), appearance: .blackPill)
                == IslandMetrics.topGap(for: .compact(.keptMusic), appearance: .liquidGlass))
        #expect(IslandAppearance.blackPill.isSolidBlack && IslandAppearance.black.isSolidBlack)
        #expect(!IslandAppearance.liquidGlass.isSolidBlack)
        #expect(IslandAppearance(rawValue: "blackPill") == .blackPill)  // the saved setting reads back
    }
}

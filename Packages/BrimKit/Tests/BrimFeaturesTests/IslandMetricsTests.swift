import CoreGraphics
import Testing
@testable import BrimCore
@testable import BrimFeatures

/// Design rules written down as tests, so a later tweak can't silently break them.
struct IslandMetricsTests {
    @Test func pillsMatchYourPicks() {
        // Mockups, 2026-09-30: glass B 128 × 34, black D 185 × 32; the title peek keeps the height.
        #expect(IslandMetrics.size(for: .compact(.keptMusic), appearance: .liquidGlass) == CGSize(width: 128, height: 34))
        #expect(IslandMetrics.size(for: .compact(.keptMusic), appearance: .black) == CGSize(width: 185, height: 32))
        for look in IslandAppearance.allCases {
            let kept = IslandMetrics.size(for: .compact(.keptMusic), appearance: look)
            // Volume and brightness inside the pill, at its size (2026-09-30).
            #expect(IslandMetrics.size(for: .compact(.hud(.volume)), appearance: look) == kept)
            #expect(IslandMetrics.size(for: .compact(.hud(.brightness)), appearance: look) == kept)
            #expect(IslandMetrics.size(for: .compact(.timer), appearance: look) == kept)
        }
    }

    /// Your pick from the side-by-side (2026-10-01): 59% of the pill's height, ~7 pt clear around the cover.
    @Test func pillArtworkIsYourPick() {
        #expect(IslandMetrics.pillArtSize(appearance: .liquidGlass) == 20)
        #expect(IslandMetrics.pillArtSize(appearance: .black) == 19)
    }

    /// A click from the slim line's countdown bar rightwards opens its tab (your check, 2026-10-01).
    @Test func theSlimBarStartsRightOfTheLine() {
        let all = IslandMetrics.SlimParts(line: true, dot: true, bar: true)
        #expect(IslandMetrics.slimBarStart(appearance: .liquidGlass, parts: all) == 55)  // 154 wide, bar 22
        #expect(IslandMetrics.slimBarStart(appearance: .black, parts: all) == 51)        // 134 wide, bar 16
    }

    @Test func everyGlanceHasOneSize() {
        // docs/05-interaction-model.md: one glance size, 320 × the pill's height; events only grow sideways.
        // AirPods: 260 (your pick, 2026-10-30), still the pill's height.
        let glances: [IslandActivity.Kind] = [.nowPlaying, .calendar, .timerNotice, .timerDone]
        for look in IslandAppearance.allCases {
            let height = IslandMetrics.pillSize(appearance: look).height
            for kind in glances {
                #expect(IslandMetrics.size(for: .compact(kind), appearance: look) == CGSize(width: 320, height: height), "\(kind)")
            }
            #expect(IslandMetrics.size(for: .compact(.headphones), appearance: look) == CGSize(width: 260, height: height))
            // The charging notice is pill-sized, like the volume HUD (your report, 2026-10-29).
            #expect(IslandMetrics.size(for: .compact(.battery), appearance: look) == IslandMetrics.pillSize(appearance: look))
        }
    }

    @Test func pillStaysAboveApplesHUD() {
        // Apple's volume/brightness HUD starts about 40 pt from the top of the screen (measured from your
        // screenshots, 2026-09-29). It only appears when "Show only Brim's HUD" is off; the pill stays above it.
        for look in IslandAppearance.allCases {
            #expect(IslandMetrics.pillBottom(appearance: look) <= 40)   // touching at most, never covering
        }
    }

    @Test func hudAndPillAreCapsules() {
        // "The whole island is the slider", like your iPhone's (2026-09-29): round ends on both.
        // (Values go into typed constants first: arithmetic inside #expect can be re-typed as Double.)
        for look in IslandAppearance.allCases {
            let pillRound: CGFloat = IslandMetrics.pillSize(appearance: look).height / 2
            #expect(IslandMetrics.cornerRadius(for: .compact(.hud(.volume)), appearance: look) == pillRound)
            #expect(IslandMetrics.cornerRadius(for: .compact(.nowPlaying), appearance: look) == pillRound)
            #expect(IslandMetrics.cornerRadius(for: .compact(.keptMusic), appearance: look) == pillRound)
        }
    }

    @Test func blackHangsFromTheEdgeAndGlassFloats() {
        #expect(IslandMetrics.topGap(for: .compact(.nowPlaying), appearance: .black) == 0)
        #expect(IslandMetrics.topGap(for: .expanded(.music), appearance: .black) == 0)
        #expect(IslandMetrics.topGap(for: .compact(.nowPlaying), appearance: .liquidGlass) == 6)
    }

    @Test func slimLineCoversNoToolbarControls() {
        // Toolbar buttons and fields start about 8–10 pt below the top edge. Marks never make it taller.
        let marked = IslandMetrics.SlimParts(line: true, dot: true, bar: true)
        for look in IslandAppearance.allCases {
            for parts in [IslandMetrics.SlimParts(), marked] {
                let height: CGFloat = IslandMetrics.size(for: .slim, appearance: look, slim: parts).height
                let bottom: CGFloat = IslandMetrics.topGap(for: .slim, appearance: look) + height
                #expect(bottom <= 9)
            }
        }
    }

    /// Your pick A: the line widens only by the marks it carries.
    @Test func slimMarksWidenTheLine() {
        let plainGlass: CGFloat = IslandMetrics.size(for: .slim, appearance: .liquidGlass).width
        let plainBlack: CGFloat = IslandMetrics.size(for: .slim, appearance: .black).width
        #expect(plainGlass == 120 && plainBlack == 140)                     // unchanged without marks
        let all = IslandMetrics.SlimParts(line: true, dot: true, bar: true)
        let glass: CGFloat = IslandMetrics.size(for: .slim, appearance: .liquidGlass, slim: all).width
        let black: CGFloat = IslandMetrics.size(for: .slim, appearance: .black, slim: all).width
        #expect(glass == 154)                                                // 4 + 4 + 120 + 4 + 22
        #expect(black == 170)                                                // 4 + 5 + 104 + 5 + 16, + 18 each side
        let marksOnly = IslandMetrics.SlimParts(line: false, dot: true, bar: true)
        let bare: CGFloat = IslandMetrics.size(for: .slim, appearance: .liquidGlass, slim: marksOnly).width
        #expect(bare == 30)                                                  // no music: just the marks
    }

    @Test func everyTabHasTheTabRowAndFits() {
        let music = IslandMetrics.size(for: .expanded(.music), appearance: .liquidGlass)
        #expect(music == CGSize(width: 380, height: 198))
        #expect(IslandMetrics.size(for: .expanded(.calendar), appearance: .liquidGlass, agendaRows: 3) == CGSize(width: 380, height: 192))
        #expect(IslandMetrics.size(for: .expanded(.calendar), appearance: .liquidGlass, agendaRows: 9) == CGSize(width: 380, height: 192))  // more scroll
        // The panel never resizes, so every tab plus the gap must fit inside it.
        for look in IslandAppearance.allCases {
            for page in ExpandedPage.allCases {
                let size = IslandMetrics.size(for: .expanded(page), appearance: look, agendaRows: 3, timerRows: 2)
                let bottom: CGFloat = IslandMetrics.topGap(for: .expanded(page), appearance: look) + size.height
                #expect(bottom <= IslandMetrics.panelSize.height, "\(page)")
            }
        }
    }

    @Test func blackHUDAndRingFloat() {
        // Your notes, 2026-09-30: in Black the HUD lets go of the edge (a floating capsule, no shoulders, no rim),
        // and the timer ring is a floating circle clear of the edge.
        let hud = IslandSurface.compact(.hud(.volume))
        let half: CGFloat = IslandMetrics.pillSize(appearance: .black).height / 2
        #expect(IslandMetrics.topGap(for: hud, appearance: .black) == 6)
        #expect(IslandMetrics.notchShoulder(for: hud) == 0)
        #expect(IslandMetrics.notchTopRadius(for: hud, appearance: .black) == half)
        #expect(IslandMetrics.notchTopRadius(for: .compact(.keptMusic), appearance: .black) == 0)  // the music notch hangs
        let ring = IslandMetrics.timerBubble(appearance: .black)
        #expect(ring.top == 4 && ring.side == 30)
        // A floating HUD still clears Apple's HUD (about 40 pt down).
        let hudBottom: CGFloat = IslandMetrics.topGap(for: hud, appearance: .black) + IslandMetrics.size(for: hud, appearance: .black).height
        #expect(hudBottom <= 40)
    }

    @Test func notchProfileDrivesBlackGeometry() {
        let narrow = IslandDisplayGeometry(screenSize: CGSize(width: 900, height: 600), notchWidth: 160,
                                            topSafeInset: 32, backingScale: 2)
        let wide = IslandDisplayGeometry(screenSize: CGSize(width: 1200, height: 800), notchWidth: 210,
                                         topSafeInset: 32, backingScale: 2)

        #expect(IslandMetrics.pillSize(appearance: .black, geometry: narrow).width == 160)
        #expect(IslandMetrics.pillSize(appearance: .black, geometry: wide).width == 210)
        #expect(IslandMetrics.size(for: .compact(.keptMusic), appearance: .black, geometry: wide).width == 210)
        #expect(IslandMetrics.notchShoulder(for: .compact(.keptMusic), geometry: wide) > 6)
    }

    @Test func expandedContentRespectsSmallDisplayProfile() {
        let small = IslandDisplayGeometry(screenSize: CGSize(width: 400, height: 600), notchWidth: nil,
                                           topSafeInset: 0, backingScale: 2)
        let normal = IslandDisplayGeometry(screenSize: CGSize(width: 1440, height: 900), notchWidth: 185,
                                            topSafeInset: 32, backingScale: 2)

        #expect(IslandMetrics.size(for: .expanded(.music), appearance: .liquidGlass, geometry: small).width == 352)
        #expect(IslandMetrics.size(for: .expanded(.music), appearance: .liquidGlass, geometry: normal).width == 380)
    }

    @Test func onlyNotchedDisplaysReserveTheTopSafeArea() {
        let notch = IslandDisplayGeometry(screenSize: CGSize(width: 1200, height: 800), notchWidth: 185,
                                          topSafeInset: 32, backingScale: 2)
        let noNotch = IslandDisplayGeometry(screenSize: CGSize(width: 1440, height: 900), notchWidth: nil,
                                            topSafeInset: 0, backingScale: 2)

        #expect(notch.islandTopInset == 32)
        #expect(noNotch.islandTopInset == 0)
    }
}

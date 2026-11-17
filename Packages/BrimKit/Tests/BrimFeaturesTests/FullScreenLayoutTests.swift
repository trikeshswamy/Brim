import CoreGraphics
import Testing
@testable import BrimFeatures

/// The full-screen player is laid out like Apple Music's, measured from your screenshots of Apple Music on the
/// 1440 × 900 Mac (2026-11-16) and a 1920 × 1080 TV (2026-11-14).
struct FullScreenLayoutTests {
    @Test func theMacMatchesAppleMusicThere() {
        let mac = FullScreenLayout(size: CGSize(width: 1440, height: 900))
        #expect(mac.artSize == 403)         // Apple's: 403
        #expect(mac.columnWidth == 403)     // Apple's controls: as wide as the cover
        #expect(mac.columnCenterX == 360)   // Apple's cover: centred at 360
        #expect(mac.sideX == 739)           // Apple's lyrics: from 742
        #expect(mac.lyricsSize == 38)       // Apple's: about 38 (its capital I is 26.6 pt tall)
        #expect(mac.lyricsSpacing == 47)
        #expect(mac.controlSpacing == 40)
        #expect(mac.sideX + mac.lyricsWidth <= 1440 * 0.94)
    }

    @Test func aTVMatchesAppleMusicThere() {
        let tv = FullScreenLayout(size: CGSize(width: 1920, height: 1080))
        #expect(tv.artSize == 404)          // Apple's: 392
        #expect(tv.columnWidth == 538)      // Apple's: 538
        #expect(tv.columnCenterX == 480)    // Apple's: 480
        #expect(tv.sideX == 985)            // Apple's: 983
        #expect(tv.lyricsWidth >= 809)      // Apple's longest line there: 809
        #expect(tv.lyricsSize == 50.5)      // Apple's: about 50
        #expect(tv.controlSpacing == 70)
    }

    @Test func theTwoSidesNeverOverlap() {
        for size in [CGSize(width: 1280, height: 800), CGSize(width: 1440, height: 900), CGSize(width: 1920, height: 1080),
                     CGSize(width: 2560, height: 1440), CGSize(width: 3440, height: 1440), CGSize(width: 1024, height: 768)] {
            let layout = FullScreenLayout(size: size)
            #expect(layout.columnCenterX + layout.columnWidth / 2 < layout.sideX, "\(size)")
            #expect(layout.sideX + layout.lyricsWidth < size.width, "\(size)")
            #expect(layout.artSize <= layout.columnWidth, "\(size)")
        }
    }

    @Test func aWideShortScreenSizesByItsHeight() {
        let wide = FullScreenLayout(size: CGSize(width: 3440, height: 1080))
        let tv = FullScreenLayout(size: CGSize(width: 1920, height: 1080))
        #expect(wide.lyricsSize == tv.lyricsSize)
        #expect(wide.columnWidth == tv.columnWidth)
    }
}

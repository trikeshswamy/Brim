import SwiftUI
import Testing
@testable import BrimCore
@testable import BrimFeatures

/// The sweep finds its lines in text SwiftUI really draws, top line first (else the glow would light the
/// wrong line).
struct SweepLineTests {
    @Test func findsTheWrappedLinesOfRealText() throws {
        let look = SweepLook(text: "counting every window still awake along the avenue tonight", size: 30, weight: .bold,
                             lineLimit: nil, color: .white, scheme: .dark, scale: 2)
        let image = try #require(look.render(width: 600))           // the full-screen lyrics column
        let alpha = try #require(SweepLayerView.alpha(of: image))
        let bands = SweepBands.detect(alpha: alpha, width: image.width, height: image.height)
        #expect(bands.count == 2)                                   // wraps onto two lines at 600 pt
        let narrow = try #require(look.render(width: 420))
        #expect(SweepBands.detect(alpha: try #require(SweepLayerView.alpha(of: narrow)),
                                  width: narrow.width, height: narrow.height).count == 3)
        #expect(bands[0].maxY < bands[1].minY)                      // the top line comes first
        #expect(bands[0].minY < CGFloat(image.height) / 2)          // …and it really is at the top
        #expect(bands[0].width > bands[1].width * 0.5)
    }

    @Test func aShortLineIsOneBand() throws {
        let look = SweepLook(text: "Easy", size: 15, weight: .bold, lineLimit: 2, color: .white, scheme: .dark, scale: 2)
        let image = try #require(look.render(width: 220))
        let bands = SweepBands.detect(alpha: try #require(SweepLayerView.alpha(of: image)), width: image.width, height: image.height)
        #expect(bands.count == 1)
    }
}

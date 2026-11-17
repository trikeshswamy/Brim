import CoreGraphics
import Testing
@testable import BrimCore

struct ArtworkPaletteTests {
    /// A 48 × 48 test image: the background colour, with an optional patch covering `patchShare` of it.
    private func image(background: (Double, Double, Double, Double),
                       patch: (Double, Double, Double)? = nil, patchShare: Double = 0) -> CGImage {
        let side = 48
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: background.0, green: background.1, blue: background.2, alpha: background.3)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        if let patch {
            context.setFillColor(red: patch.0, green: patch.1, blue: patch.2, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: Double(side) * patchShare, height: Double(side)))
        }
        return context.makeImage()!
    }

    @Test func solidRedIsRed() throws {
        let tint = try #require(ArtworkPalette.tint(of: image(background: (0.9, 0.1, 0.1, 1))))
        #expect(tint.hue < 0.02 || tint.hue > 0.98)
        #expect(tint.saturation > 0.8)
    }

    @Test func greyArtHasNoTint() {
        #expect(ArtworkPalette.tint(of: image(background: (0.5, 0.5, 0.5, 1))) == nil)
        #expect(ArtworkPalette.tint(of: image(background: (0.02, 0.02, 0.02, 1))) == nil)
    }

    @Test func vividPatchBeatsGreyBackground() throws {
        let art = image(background: (0.45, 0.45, 0.45, 1), patch: (0.1, 0.3, 0.95), patchShare: 0.25)
        let tint = try #require(ArtworkPalette.tint(of: art))
        #expect(abs(tint.hue - 0.62) < 0.05)  // blue
    }

    @Test func tinySpeckOfColourCountsAsBlackAndWhite() {
        let art = image(background: (0.3, 0.3, 0.3, 1), patch: (0.95, 0.5, 0.1), patchShare: 0.02)
        #expect(ArtworkPalette.tint(of: art) == nil)
    }

    @Test func transparentArtHasNoTint() {
        #expect(ArtworkPalette.tint(of: image(background: (1, 0, 0, 0))) == nil)
    }

    @Test func severalColoursMostProminentFirst() {
        // 60% blue, 40% orange: both count, blue first.
        let art = image(background: (0.95, 0.5, 0.1, 1), patch: (0.1, 0.3, 0.95), patchShare: 0.6)
        let colors = ArtworkPalette.colors(of: art, count: 4)
        #expect(colors.count == 2)
        #expect(abs(colors[0].hue - 0.62) < 0.05)  // blue
        #expect(abs(colors[1].hue - 0.08) < 0.05)  // orange
    }

    @Test func backgroundToneIsDeep() {
        let bright = TintColor(hue: 0.5, saturation: 0.1, brightness: 1).background()
        #expect(bright.brightness == 0.45)
        #expect(bright.saturation == 0.35)
        #expect(TintColor(hue: 0.5, saturation: 1, brightness: 0.1).background().brightness == 0.22)
    }

    @Test func readableColourIsBrightOnDarkAndDeepOnLight() {
        let dim = TintColor(hue: 0.1, saturation: 0.95, brightness: 0.4)
        #expect(dim.readable(onDark: true).brightness == 0.85)
        #expect(dim.readable(onDark: true).saturation == 0.9)
        #expect(dim.readable(onDark: false).brightness == 0.4)
        let pale = TintColor(hue: 0.1, saturation: 0.1, brightness: 1)
        #expect(pale.readable(onDark: false).brightness == 0.55)
        #expect(pale.readable(onDark: false).saturation == 0.35)
    }
}

import CoreGraphics

/// A colour as hue, saturation, and brightness, each 0...1.
public struct TintColor: Equatable, Sendable {
    public var hue: Double
    public var saturation: Double
    public var brightness: Double

    public init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }

    /// Keeps the colour readable on the island: bright on a dark island, deep on a light one.
    public func readable(onDark: Bool) -> TintColor {
        TintColor(hue: hue,
                  saturation: min(max(saturation, 0.35), 0.9),
                  brightness: onDark ? max(brightness, 0.85) : min(brightness, 0.55))
    }

    /// A deep version for the full-screen player's background, so white lyrics stay readable on it.
    public func background() -> TintColor {
        TintColor(hue: hue,
                  saturation: min(max(saturation, 0.35), 0.85),
                  brightness: min(max(brightness * 0.55, 0.22), 0.45))
    }
}

/// Picks the waveform's colour from the album art, like the iPhone's Dynamic Island.
public enum ArtworkPalette {
    /// The art's most prominent vivid colour, or nil when the art is black, white, or grey.
    /// Reads a 24 × 24 thumbnail (576 pixels), so it takes well under a millisecond.
    public static func tint(of image: CGImage) -> TintColor? {
        colors(of: image, count: 1).first
    }

    /// Up to `count` prominent vivid colours, most prominent first (for the full-screen background).
    /// A colour needs at least 15% of the top colour's weight to count. Empty for black-and-white art.
    public static func colors(of image: CGImage, count: Int) -> [TintColor] {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return [] }

        // 12 hue buckets of 30°, with red centred on bucket 0 so it isn't split in two.
        // Vivid, bright pixels weigh the most; greys, near-black, and near-white don't count.
        var weight = [Double](repeating: 0, count: 12)
        var red = [Double](repeating: 0, count: 12)
        var green = [Double](repeating: 0, count: 12)
        var blue = [Double](repeating: 0, count: 12)
        var visible = 0
        var vivid = 0

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.5 else { continue }
            visible += 1
            let r = Double(pixels[index]) / 255 / alpha
            let g = Double(pixels[index + 1]) / 255 / alpha
            let b = Double(pixels[index + 2]) / 255 / alpha
            let hsb = Self.hsb(r, g, b)
            guard hsb.saturation >= 0.25, hsb.brightness >= 0.2 else { continue }
            vivid += 1
            let bucket = Int(hsb.hue * 12 + 0.5) % 12
            let w = hsb.saturation * hsb.brightness
            weight[bucket] += w
            red[bucket] += r * w
            green[bucket] += g * w
            blue[bucket] += b * w
        }

        // Fewer than 1 in 20 pixels with real colour: treat the art as black-and-white.
        guard visible > 0, Double(vivid) / Double(visible) >= 0.05,
              let top = weight.max(), top > 0 else { return [] }

        return weight.indices
            .filter { weight[$0] >= top * 0.15 }
            .sorted { weight[$0] > weight[$1] }
            .prefix(count)
            .map { bucket in
                let hsb = Self.hsb(red[bucket] / weight[bucket], green[bucket] / weight[bucket], blue[bucket] / weight[bucket])
                return TintColor(hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness)
            }
    }

    /// Standard RGB → HSB conversion.
    static func hsb(_ r: Double, _ g: Double, _ b: Double) -> TintColor {
        let maxValue = max(r, g, b)
        let minValue = min(r, g, b)
        let delta = maxValue - minValue
        let saturation = maxValue == 0 ? 0 : delta / maxValue
        guard delta > 0 else { return TintColor(hue: 0, saturation: 0, brightness: maxValue) }
        var hue: Double
        if maxValue == r {
            hue = (g - b) / delta
        } else if maxValue == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return TintColor(hue: hue, saturation: saturation, brightness: maxValue)
    }
}

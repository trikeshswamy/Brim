import AppKit
import QuartzCore
import SwiftUI
import BrimCore

/// The full-screen player's slow-moving colour: four soft blobs of the art's colours drifting and breathing.
/// Core Animation plays the motion in macOS's render server, so Brim does no work per frame (the same approach as
/// the waveform and the progress bar). 15 frames a second is plenty for motion this slow.
/// Reduce Motion: the blobs stand still. A new song's colours cross-fade over a second.
struct MovingBackground: View {
    let colors: [TintColor]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.offscreenRender) private var offscreenRender

    var body: some View {
        if offscreenRender {
            Color.clear  // the still gradient underneath shows instead
        } else {
            BlobLayers(colors: Self.tones(colors), moves: !reduceMotion)
                .accessibilityHidden(true)
        }
    }

    /// Four deep tones, repeating the art's colours if it has fewer; a deep grey for black-and-white art.
    static func tones(_ colors: [TintColor]) -> [NSColor] {
        let base = colors.isEmpty ? [TintColor(hue: 0, saturation: 0, brightness: 0.2)] : colors
        return (0..<4).map { index in
            let tone = base[index % base.count].background()
            return NSColor(hue: tone.hue, saturation: tone.saturation, brightness: min(tone.brightness * 1.25, 0.55), alpha: 1)
        }
    }
}

private struct BlobLayers: NSViewRepresentable {
    let colors: [NSColor]
    let moves: Bool

    func makeNSView(context: Context) -> BlobView { BlobView() }

    func updateNSView(_ view: BlobView, context: Context) {
        view.update(colors: colors, moves: moves)
    }
}

final class BlobView: NSView {
    /// Where each blob lives (fractions of the screen) and how long one drift loop takes, so the four never sync up.
    private static let homes: [CGPoint] = [CGPoint(x: 0.22, y: 0.72), CGPoint(x: 0.8, y: 0.78),
                                           CGPoint(x: 0.72, y: 0.22), CGPoint(x: 0.18, y: 0.2)]
    private static let loops: [CFTimeInterval] = [34, 41, 29, 37]

    private var blobs: [CAGradientLayer] = []
    private var moving = false
    private var laidOutSize: CGSize = .zero

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for _ in Self.homes {
            let blob = CAGradientLayer()
            blob.type = .radial
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1, y: 1)
            layer?.addSublayer(blob)
            blobs.append(blob)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        place()
    }

    func update(colors: [NSColor], moves: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(1)  // a new song's colours cross-fade
        for (blob, color) in zip(blobs, colors) {
            blob.colors = [color.withAlphaComponent(0.95).cgColor, color.withAlphaComponent(0).cgColor]
        }
        CATransaction.commit()
        if moves != moving {
            moving = moves
            place()
        }
    }

    /// Sizes and positions the blobs for the screen, then starts (or stops) their drift.
    private func place() {
        let size = bounds.size
        guard size.width > 0 else { return }
        let diameter = max(size.width, size.height) * 0.75
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, blob) in blobs.enumerated() {
            let home = CGPoint(x: Self.homes[index].x * size.width, y: Self.homes[index].y * size.height)
            blob.removeAllAnimations()
            blob.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            blob.position = home
            if moving { drift(blob, around: home, size: size, loop: Self.loops[index]) }
        }
        CATransaction.commit()
    }

    private func drift(_ blob: CALayer, around home: CGPoint, size: CGSize, loop: CFTimeInterval) {
        let reach = CGSize(width: size.width * 0.14, height: size.height * 0.14)
        let path = [home,
                    CGPoint(x: home.x + reach.width, y: home.y - reach.height * 0.5),
                    CGPoint(x: home.x + reach.width * 0.3, y: home.y + reach.height),
                    CGPoint(x: home.x - reach.width, y: home.y + reach.height * 0.4),
                    home]
        let wander = CAKeyframeAnimation(keyPath: "position")
        wander.values = path.map { NSValue(point: $0) }
        wander.calculationMode = .cubic
        wander.duration = loop
        wander.repeatCount = .infinity
        wander.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 20, preferred: 15)
        blob.add(wander, forKey: "wander")

        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = 0.9
        breathe.toValue = 1.15
        breathe.duration = loop / 2
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breathe.preferredFrameRateRange = wander.preferredFrameRateRange
        blob.add(breathe, forKey: "breathe")
    }
}

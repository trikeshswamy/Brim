import AppKit
import SwiftUI
import BrimCore

/// The current lyric line lighting up letter by letter, as they're sung (estimated; your pick 2026-09-30).
///
/// Played by Core Animation: the lit text is drawn once per line (SwiftUI renders the same text at the same
/// width, so it lines up exactly), and a soft-edged mask slides across each visual line in reading order.
/// macOS's render server moves the mask, so Brim does no work per frame. (The first version redrew the text
/// 30 times a second in SwiftUI: 19% CPU in full screen, measured.)
///
/// Off in Settings, with Reduce Motion, in snapshots, or when the line has no words: plain text, fully lit.
struct SweepLine: View {
    let text: String
    let size: CGFloat
    let weight: Font.Weight
    var lineLimit: Int?
    /// The lit colour; the letters not yet sung show at `dim` of it.
    var color: Color = .primary
    let dim: Double
    /// Nil: no sweep.
    let clock: SweepClock?
    /// How long the line takes to move into place once it starts sweeping: the lit letters wait for it (the island's
    /// line slides in for 0.3 s; full-screen lyrics pass `LyricsColumn.arrival`).
    var revealAfter: TimeInterval = 0.3
    /// The lit letters are showing.
    @State private var revealed = false
    /// The sweep from the moment the line arrived (`SweepClock.startingNow`), until the song pauses, plays or jumps.
    @State private var startClock: SweepClock?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.offscreenRender) private var offscreenRender
    @Environment(\.displayScale) private var scale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let sweeping = clock != nil && !reduceMotion && !offscreenRender
        // A line that starts sweeping arrives as letters not yet sung (dim, like Apple Music's); once it's in place the
        // sweep starts from its first letter. 0.13.5 showed it all lit until then, so the whole line flashed before
        // the sweep (your check, 2026-10-01). A line that stops sweeping is all lit text again in the same instant.
        // (Scoped to the opacity: see LyricRow's blur.)
        let dimmed = sweeping
        Text(text)
            .font(.system(size: size, weight: weight))
            .lineLimit(lineLimit)
            .foregroundStyle(color)
            .animation(dimmed ? .easeInOut(duration: 0.3) : nil) { $0.opacity(dimmed ? dim : 1) }
            .overlay {
                if sweeping, let clock {
                    SweepLayer(look: SweepLook(text: text, size: size, weight: weight, lineLimit: lineLimit, color: color,
                                               scheme: colorScheme, scale: scale),
                               clock: startClock ?? clock, edge: size * 1.3, revealed: revealed, fade: Self.fade)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        // Comes and goes at once, never faded by SwiftUI: an AppKit view doesn't follow SwiftUI's
                        // animated moves (it sits where the line is going), so it stays hidden until the line arrives.
                        .transition(.identity)
                }
            }
            .task(id: sweeping) {
                revealed = false
                startClock = nil
                guard sweeping else { return }
                try? await Task.sleep(for: .seconds(revealAfter))
                guard !Task.isCancelled else { return }
                startClock = clock?.startingNow()
                revealed = true
            }
            // Paused, played or moved: follow the song's own timing again.
            .onChange(of: clock) { _, _ in if revealed { startClock = nil } }
    }

    /// The lit letters fade in (and the rest dim) over this long.
    static let fade: TimeInterval = 0.2
}

/// What the lit text looks like; a change means drawing it again.
struct SweepLook: Equatable {
    var text: String
    var size: CGFloat
    var weight: Font.Weight
    var lineLimit: Int?
    var color: Color
    var scheme: ColorScheme
    var scale: CGFloat

    /// The same text as the row, fully lit, at `width`.
    @MainActor
    func render(width: CGFloat) -> CGImage? {
        let content = Text(text)
            .font(.system(size: size, weight: weight))
            .lineLimit(lineLimit)
            .foregroundStyle(color)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        return renderer.cgImage
    }
}

private struct SweepLayer: NSViewRepresentable {
    let look: SweepLook
    let clock: SweepClock
    let edge: CGFloat
    let revealed: Bool
    let fade: TimeInterval

    func makeNSView(context: Context) -> SweepLayerView { SweepLayerView() }

    func updateNSView(_ view: SweepLayerView, context: Context) {
        view.update(look: look, clock: clock, edge: edge)
        view.reveal(revealed, fade: fade)
    }
}

final class SweepLayerView: NSView {
    private let litLayer = CALayer()
    private let maskLayer = CALayer()
    private var lineMasks: [CAGradientLayer] = []
    /// The visual lines in `litLayer` coordinates (origin bottom-left).
    private var lines: [CGRect] = []
    private var look: SweepLook?
    private var clock: SweepClock?
    private var edge: CGFloat = 20
    private var renderedWidth: CGFloat = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        litLayer.mask = maskLayer
        litLayer.opacity = 0  // hidden until SweepLine reveals it
        layer?.addSublayer(litLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// SwiftUI puts this view where its line is going at once, while the line itself glides there, so the lit text
    /// stays hidden until SweepLine says the line has arrived. 0.13.3 showed it after a fixed 0.35 s: with the 0.5 s
    /// spring (0.13.4) the line was still ~13 pt short, so the first word showed twice (your test, 2026-10-01).
    private var shown = false

    func reveal(_ show: Bool, fade: TimeInterval) {
        guard show != shown else { return }
        shown = show
        CATransaction.begin()
        CATransaction.setDisableActions(!show)
        if show {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0
            animation.toValue = 1
            animation.duration = fade
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            litLayer.add(animation, forKey: "reveal")
        }
        litLayer.opacity = show ? 1 : 0
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        guard abs(bounds.width - renderedWidth) > 0.5 else { return }
        redraw()
        play()
    }

    func update(look: SweepLook, clock: SweepClock, edge: CGFloat) {
        self.edge = edge
        if look != self.look {
            self.look = look
            redraw()
            self.clock = clock
            play()
        } else if clock != self.clock {
            self.clock = clock
            play()
        }
    }

    /// Draws the lit text once and finds its visual lines.
    private func redraw() {
        guard let look, bounds.width > 0, let image = look.render(width: bounds.width) else { return }
        renderedWidth = bounds.width
        let size = CGSize(width: CGFloat(image.width) / look.scale, height: CGFloat(image.height) / look.scale)
        withoutAnimation {
            litLayer.contents = image
            litLayer.contentsScale = look.scale
            // Top-aligned with the row, like the text underneath.
            litLayer.frame = CGRect(x: 0, y: bounds.height - size.height, width: size.width, height: size.height)
            maskLayer.frame = litLayer.bounds
        }
        let bands = Self.alpha(of: image).map {
            SweepBands.detect(alpha: $0, width: image.width, height: image.height)
        } ?? []
        // Pixels (top-left origin) → points in litLayer (bottom-left origin).
        lines = bands.map { band in
            CGRect(x: band.minX / look.scale, y: size.height - band.maxY / look.scale,
                   width: band.width / look.scale, height: band.height / look.scale).insetBy(dx: 0, dy: -2)
        }
        lineMasks.forEach { $0.removeFromSuperlayer() }
        lineMasks = lines.map { _ in
            let mask = CAGradientLayer()
            mask.startPoint = CGPoint(x: 0, y: 0.5)
            mask.endPoint = CGPoint(x: 1, y: 0.5)
            mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            maskLayer.addSublayer(mask)
            return mask
        }
    }

    /// Places each line's mask where the sweep is now and, while playing, hands the rest to Core Animation.
    private func play() {
        guard let clock, !lines.isEmpty else { return }
        let steps = SweepPlan.steps(for: lines, edge: edge, clock: clock, at: .now)
        let now = CACurrentMediaTime()
        withoutAnimation {
            for (index, step) in steps.enumerated() {
                let mask = lineMasks[index]
                let line = lines[index]
                // Opaque up to the front, then a soft edge `edge` wide: the mask's right end is the front.
                let width = line.width + 2 * edge
                mask.removeAllAnimations()
                mask.bounds = CGRect(x: 0, y: 0, width: width, height: line.height)
                mask.locations = [0, NSNumber(value: Double((width - edge) / width)), 1]
                mask.position = CGPoint(x: step.from - width / 2, y: line.midY)
                guard let delay = step.delay, step.duration > 0 else { continue }
                let motion = CABasicAnimation(keyPath: "position.x")
                motion.fromValue = step.from - width / 2
                motion.toValue = step.to - width / 2
                motion.beginTime = now + delay
                motion.duration = step.duration
                motion.timingFunction = CAMediaTimingFunction(name: .linear)
                motion.fillMode = .both
                motion.isRemovedOnCompletion = false
                mask.add(motion, forKey: "sweep")
            }
        }
    }

    /// The image's alpha channel, top row first.
    static func alpha(of image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    private func withoutAnimation(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}

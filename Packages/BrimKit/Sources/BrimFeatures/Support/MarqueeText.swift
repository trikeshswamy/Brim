import AppKit
import SwiftUI

/// Text that scrolls in a loop when it doesn't fit, like Apple Music's full-screen player (your video "Scrolling animation
/// of the title music", measured 2026-10-29; your pick: everywhere):
/// - only when the text is wider than its space; text that fits never moves;
/// - it rests with its start in place, glides left at about 30 pt a second (a short ease at each end), and a second copy
///   follows a gap behind, so the start comes round into the same place; then it rests again and repeats;
/// - soft fades at both cut edges, the left one just outside the text's own edge (`bleed`), as Apple's is;
/// - `onceKey`: one pass per key, for the 3 s song peek (it's gone before a second pass);
/// - Reduce Motion: no movement, just the fade at the cut edge.
/// The loop is played by Core Animation, like the lyric sweep (SweepLine): the line is drawn once as a picture and macOS
/// moves it, so Brim does no work per frame. Driven by SwiftUI it cost ~6% CPU while it moved (measured 2026-10-29).
struct MarqueeText<Content: View>: View {
    /// A new value starts over from the rest (a new song, or the view appearing).
    let trigger: AnyHashable
    /// When set, scrolls at most once per key while Brim runs (the pill's peek: once per song).
    var onceKey: String?
    /// The space between the end and the next copy's start (Apple's: about 3.5 × the text size).
    var gap: CGFloat = 40
    /// How far the moving text shows past its left edge, fading out (Apple's full screen: about 1.5 × the text size).
    var bleed: CGFloat = 12
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var contentWidth: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    /// The pill's peek scrolls once per song: false once its one pass has been used.
    @State private var allowed = true

    private var overflows: Bool { MarqueePlan.scrolls(overflow: contentWidth - boxWidth) }
    private var moving: Bool { overflows && !reduceMotion && allowed }

    var body: some View {
        content
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { contentWidth = $0.width; contentHeight = $0.height }
            // As wide as the text, or narrower when the row runs out of room. minWidth 0 matters: without it the
            // frame won't shrink below the text's full width and pushes the pill's art and waveform out (snapshot, P-3).
            .frame(minWidth: 0, maxWidth: contentWidth > 0 ? contentWidth : nil, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { boxWidth = $0 }
            .clipped()
            .mask { restingFade }
            // This copy holds the layout (and is what VoiceOver reads); while the text loops, the two moving copies
            // drawn over it are what you see.
            .opacity(moving ? 0 : 1)
            .overlay(alignment: .leading) { if moving { loop } }
            .task(id: LoopID(trigger: trigger, moving: overflows && !reduceMotion)) {
                // The peek's one pass per song, decided the moment there's something to scroll.
                guard let onceKey, overflows, !reduceMotion else { allowed = true; return }
                allowed = MarqueeMemory.firstTime(onceKey)
            }
    }

    /// The line drawn once and looped by Core Animation over the box plus the bleed on its left.
    private var loop: some View {
        MarqueeLayer(look: MarqueeLook(key: LoopID(trigger: trigger, moving: true), width: contentWidth, height: contentHeight,
                                       scheme: colorScheme, scale: displayScale),
                     draw: { look in
                         let renderer = ImageRenderer(content: content.fixedSize().environment(\.colorScheme, look.scheme))
                         renderer.scale = look.scale
                         return renderer.cgImage
                     },
                     gap: gap, bleed: bleed, repeats: onceKey == nil)
            .frame(width: boxWidth + bleed, height: contentHeight)
            .offset(x: -bleed)
            .accessibilityHidden(true)
            .allowsHitTesting(false)  // only a picture: never in the way of the pointer (the artwork's hover beside it)
    }

    /// Resting, or with Reduce Motion: only the cut end fades.
    private var restingFade: some View {
        HStack(spacing: 0) {
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: overflows ? MarqueePlan.edgeFade : 0)
        }
    }

    private struct LoopID: Hashable {
        let trigger: AnyHashable
        let moving: Bool
    }
}

/// What the moving picture shows; a change means drawing it again.
struct MarqueeLook: Equatable {
    var key: AnyHashable
    var width: CGFloat
    var height: CGFloat
    var scheme: ColorScheme
    var scale: CGFloat
}

/// The loop on Core Animation: two copies of the picture a gap apart, one keyframe animation (rest, glide, back to the
/// identical start) repeating on the render server, and a mask fading both ends.
private struct MarqueeLayer: NSViewRepresentable {
    let look: MarqueeLook
    let draw: @MainActor (MarqueeLook) -> CGImage?
    let gap: CGFloat
    let bleed: CGFloat
    let repeats: Bool

    func makeNSView(context: Context) -> MarqueeLayerView { MarqueeLayerView() }

    func updateNSView(_ view: MarqueeLayerView, context: Context) {
        view.update(look: look, draw: draw, gap: gap, bleed: bleed, repeats: repeats)
    }
}

final class MarqueeLayerView: NSView {
    private let strip = CALayer()
    private let first = CALayer()
    private let second = CALayer()
    private let fade = CAGradientLayer()
    private var look: MarqueeLook?
    private var shape: (gap: CGFloat, bleed: CGFloat, repeats: Bool, size: CGSize)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        strip.addSublayer(first)
        strip.addSublayer(second)
        layer?.addSublayer(strip)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.mask = fade
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        if let look, let shape, shape.size != bounds.size { place(look: look, gap: shape.gap, bleed: shape.bleed, repeats: shape.repeats) }
    }

    @MainActor
    func update(look: MarqueeLook, draw: (MarqueeLook) -> CGImage?, gap: CGFloat, bleed: CGFloat, repeats: Bool) {
        if look != self.look {
            self.look = look
            let image = draw(look)
            withoutAnimation {
                first.contents = image
                second.contents = image
                first.contentsScale = look.scale
                second.contentsScale = look.scale
            }
            place(look: look, gap: gap, bleed: bleed, repeats: repeats)
        } else if shape?.gap != gap || shape?.bleed != bleed || shape?.repeats != repeats {
            place(look: look, gap: gap, bleed: bleed, repeats: repeats)
        }
    }

    /// Lays out the copies and the fades, and (re)starts the loop from its rest.
    private func place(look: MarqueeLook, gap: CGFloat, bleed: CGFloat, repeats: Bool) {
        shape = (gap, bleed, repeats, bounds.size)
        guard bounds.width > 0, look.width > 0 else { return }
        let distance = look.width + gap
        withoutAnimation {
            let y = (bounds.height - look.height) / 2
            first.frame = CGRect(x: 0, y: 0, width: look.width, height: look.height)
            second.frame = CGRect(x: distance, y: 0, width: look.width, height: look.height)
            strip.removeAllAnimations()
            strip.frame = CGRect(x: bleed, y: y, width: distance + look.width, height: look.height)
            fade.frame = bounds
            let edge = MarqueePlan.edgeFade
            fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            fade.locations = [0, NSNumber(value: Double(bleed / bounds.width)),
                              NSNumber(value: Double(max(0, bounds.width - edge) / bounds.width)), 1]
        }
        let glide = MarqueePlan.glide(distance: distance)
        let rest = MarqueePlan.rest
        let cycle = rest + glide.duration
        let start = strip.position.x
        let motion = CAKeyframeAnimation(keyPath: "position.x")
        motion.values = [start, start, start - distance]
        motion.keyTimes = [0, NSNumber(value: rest / cycle), 1]
        motion.timingFunctions = [CAMediaTimingFunction(name: .linear),
                                  CAMediaTimingFunction(controlPoints: Float(glide.ease), 0, Float(1 - glide.ease), 1)]
        motion.duration = cycle
        motion.repeatCount = repeats ? .infinity : 1
        // The first rest is shorter: start part-way into it.
        motion.beginTime = strip.convertTime(CACurrentMediaTime(), from: nil) - (rest - MarqueePlan.firstRest)
        motion.isRemovedOnCompletion = true
        strip.add(motion, forKey: "marquee")
    }

    private func withoutAnimation(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}

/// The marquee's timing, in one place (and unit-tested). Measured from your video of Apple Music (2026-10-29): it rests
/// about 3.5 s, moves about 30 pt a second, eases for about half a second at each end.
enum MarqueePlan {
    static let speed: CGFloat = 30
    /// Rest between loops.
    static let rest: TimeInterval = 3.5
    /// Rest before the first pass: shorter, so a glance at the island still sees it move.
    static let firstRest: TimeInterval = 2
    /// Seconds of easing at each end of a glide.
    static let easing: TimeInterval = 0.5
    static let edgeFade: CGFloat = 12

    /// A sliver under 2 pt isn't worth moving for.
    static func scrolls(overflow: CGFloat) -> Bool { overflow >= 2 }

    /// One glide over `distance` (the text plus the gap): steady at `speed` in the middle, with `easing` seconds of
    /// ease at each end; `ease` is the timing curve's control point (the share of the time spent easing).
    static func glide(distance: CGFloat) -> (duration: TimeInterval, ease: Double) {
        let duration = TimeInterval(distance / speed) + easing
        return (duration, min(0.45, easing / duration))
    }
}

/// Remembers which keys have already scrolled, so the pill glides once per song, not after every volume change.
enum MarqueeMemory {
    private static var seen: [String] = []

    /// True the first time a key is seen. Keeps the last 200 keys.
    static func firstTime(_ key: String) -> Bool {
        guard !seen.contains(key) else { return false }
        seen.append(key)
        if seen.count > 200 { seen.removeFirst(seen.count - 200) }
        return true
    }
}

import AppKit
import QuartzCore
import SwiftUI
import BrimCore

/// The moving bars in the music pill, tinted from the album art (like the iPhone's Dynamic Island).
/// - Playing: the bars bounce in a fixed, natural-looking pattern (not audio-reactive; see backlog).
/// - Paused: they settle into a row of dots.
/// - Reduce Motion: still bars while playing.
struct WaveformView: View {
    let isPlaying: Bool
    let tint: TintColor?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.offscreenRender) private var offscreenRender

    var body: some View {
        Group {
            if offscreenRender {
                HStack(spacing: 1.75) {  // still stand-in for snapshots
                    ForEach([0.55, 0.8, 1.0, 0.75, 0.6], id: \.self) { share in
                        Capsule().fill(Color(nsColor: color)).frame(width: 2.5, height: 16 * share * (isPlaying ? 0.8 : 0.2))
                    }
                }
            } else {
                WaveformBars(color: color, playing: isPlaying, moves: !reduceMotion)
            }
        }
        .frame(width: WaveformLayerView.size.width, height: WaveformLayerView.size.height)
        .accessibilityHidden(true)
    }

    private var color: NSColor { ArtColor.resolve(tint, onDark: colorScheme == .dark) }
}

/// Bridges SwiftUI to the Core Animation view below. SwiftUI calls `updateNSView` only when an input changes.
private struct WaveformBars: NSViewRepresentable {
    let color: NSColor
    let playing: Bool
    let moves: Bool

    func makeNSView(context: Context) -> WaveformLayerView { WaveformLayerView() }

    func updateNSView(_ view: WaveformLayerView, context: Context) {
        view.update(color: color, playing: playing, moves: moves)
    }
}

/// Five bars drawn with Core Animation.
/// Each bar gets one repeating animation, which macOS's render server plays by itself:
/// Brim's process does no work per frame and gets no timer.
final class WaveformLayerView: NSView {
    static let size = CGSize(width: 20, height: 16)
    private static let barWidth: CGFloat = 2.5
    private static let gap: CGFloat = 1.75
    private static let dotHeight: CGFloat = 3
    /// Each bar's share of the full height: tallest in the middle, like a real waveform.
    private static let envelope: [CGFloat] = [0.55, 0.8, 1.0, 0.75, 0.6]
    /// Hand-picked heights (share of each bar's peak). A loop is 8 moves; the last value returns to the first.
    private static let patterns: [[CGFloat]] = [
        [0.45, 0.80, 0.35, 0.65, 0.95, 0.50, 0.70, 0.40],
        [0.70, 0.40, 0.90, 0.55, 0.30, 0.85, 0.50, 1.00],
        [0.90, 0.55, 1.00, 0.40, 0.75, 0.95, 0.35, 0.65],
        [0.50, 0.95, 0.60, 0.85, 0.40, 0.70, 1.00, 0.45],
        [0.60, 0.35, 0.75, 0.50, 0.90, 0.40, 0.65, 0.80],
    ]
    /// A different loop length per bar, so the five together take minutes to repeat.
    private static let loopDurations: [CFTimeInterval] = [1.23, 1.57, 1.11, 1.43, 1.31]

    private enum Mode { case moving, still, dots }
    private var mode: Mode?
    private var bars: [CALayer] = []

    init() {
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        wantsLayer = true
        for _ in Self.envelope {
            let bar = CALayer()
            bar.cornerRadius = Self.barWidth / 2
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: Self.dotHeight)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Clicks and hovers belong to the island, never to the bars.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        withoutAnimation {
            let total = CGFloat(bars.count) * Self.barWidth + CGFloat(bars.count - 1) * Self.gap
            var x = (bounds.width - total) / 2 + Self.barWidth / 2
            for bar in bars {
                bar.position = CGPoint(x: x, y: bounds.midY)  // centred, so bars grow up and down
                x += Self.barWidth + Self.gap
            }
        }
    }

    func update(color: NSColor, playing: Bool, moves: Bool) {
        let cgColor = color.cgColor
        for bar in bars where bar.backgroundColor != cgColor {
            bar.backgroundColor = cgColor  // a new song's colour cross-fades (Core Animation's default 0.25 s)
        }

        let next: Mode = playing ? (moves ? .moving : .still) : .dots
        guard next != mode else { return }
        mode = next
        switch next {
        case .moving: startMoving()
        case .still: settle(to: Self.envelope.map { $0 * Self.size.height * 0.7 })
        case .dots: settle(to: Self.envelope.map { _ in Self.dotHeight })
        }
    }

    private func startMoving() {
        for (index, bar) in bars.enumerated() {
            let peak = Self.envelope[index] * Self.size.height
            var heights = Self.patterns[index].map { max(Self.dotHeight, $0 * peak) }
            heights.append(heights[0])  // close the loop so it repeats without a jump

            // Rise smoothly from wherever the bar is now, then start the loop.
            let rise = CABasicAnimation(keyPath: "bounds.size.height")
            rise.fromValue = currentHeight(of: bar)
            rise.toValue = heights[0]
            rise.duration = 0.25
            rise.timingFunction = CAMediaTimingFunction(name: .easeOut)

            let wave = CAKeyframeAnimation(keyPath: "bounds.size.height")
            wave.values = heights
            wave.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: heights.count - 1)
            wave.duration = Self.loopDurations[index]
            wave.repeatCount = .infinity
            wave.beginTime = bar.convertTime(CACurrentMediaTime(), from: nil) + rise.duration
            // 30 frames a second is smooth for bars this small and halves the drawing work.
            wave.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 60, preferred: 30)

            bar.removeAllAnimations()
            withoutAnimation { bar.bounds.size.height = heights[0] }
            bar.add(rise, forKey: "rise")
            bar.add(wave, forKey: "wave")
        }
    }

    /// Stops the loop and eases each bar to a fixed height.
    private func settle(to heights: [CGFloat]) {
        for (bar, height) in zip(bars, heights) {
            let ease = CABasicAnimation(keyPath: "bounds.size.height")
            ease.fromValue = currentHeight(of: bar)
            ease.toValue = height
            ease.duration = 0.3
            ease.timingFunction = CAMediaTimingFunction(name: .easeOut)

            bar.removeAllAnimations()
            withoutAnimation { bar.bounds.size.height = height }
            bar.add(ease, forKey: "settle")
        }
    }

    /// The height on screen right now, mid-animation included.
    private func currentHeight(of bar: CALayer) -> CGFloat {
        (bar.presentation() ?? bar).bounds.height
    }

    private func withoutAnimation(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}

import AppKit
import QuartzCore
import SwiftUI

/// The progress bar's fill, moved by Core Animation: Brim sets it once per change ("from here to the end of the
/// song over N seconds") and macOS's render server draws the movement. Brim does no work per frame.
/// (A SwiftUI animation here re-laid out the whole full-screen player every frame: 25% CPU, measured.)
struct ProgressBar: View {
    /// 0 … 1, where the song is right now.
    let fraction: Double
    /// Seconds until the fill reaches the end at normal speed; nil while paused or unknown (the fill stays put).
    let secondsToEnd: TimeInterval?
    var height: CGFloat = 4
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.offscreenRender) private var offscreenRender

    var body: some View {
        Group {
            if offscreenRender {
                GeometryReader { proxy in  // still stand-in for snapshots
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.2))
                        Capsule().fill(Color.primary).frame(width: proxy.size.width * min(max(fraction, 0), 1))
                    }
                }
            } else {
                ProgressBarLayers(fraction: fraction, secondsToEnd: secondsToEnd,
                                  fill: colorScheme == .dark ? .white : .black,
                                  track: (colorScheme == .dark ? NSColor.white : NSColor.black).withAlphaComponent(0.2))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct ProgressBarLayers: NSViewRepresentable {
    let fraction: Double
    let secondsToEnd: TimeInterval?
    let fill: NSColor
    let track: NSColor

    func makeNSView(context: Context) -> ProgressBarLayerView { ProgressBarLayerView() }

    func updateNSView(_ view: ProgressBarLayerView, context: Context) {
        view.update(fraction: fraction, secondsToEnd: secondsToEnd, fill: fill, track: track)
    }
}

final class ProgressBarLayerView: NSView {
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private var fraction: Double = 0
    private var secondsToEnd: TimeInterval?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        fillLayer.anchorPoint = .zero
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        restart()  // the width changed: redo the fill for the new size
    }

    func update(fraction: Double, secondsToEnd: TimeInterval?, fill: NSColor, track: NSColor) {
        withoutAnimation {
            trackLayer.backgroundColor = track.cgColor
            fillLayer.backgroundColor = fill.cgColor
        }
        // Only a real jump (seek, new song, pause/play) restarts the motion; the running animation already
        // matches small corrections, so updates that change nothing cost nothing.
        let drift = abs(fraction - currentFraction())
        guard drift > 0.004 || (secondsToEnd == nil) != (self.secondsToEnd == nil) else { return }
        self.fraction = fraction
        self.secondsToEnd = secondsToEnd
        restart()
    }

    private func restart() {
        let width = bounds.width
        let height = bounds.height
        withoutAnimation {
            trackLayer.frame = bounds
            trackLayer.cornerRadius = height / 2
            fillLayer.cornerRadius = height / 2
            fillLayer.position = .zero
            fillLayer.removeAllAnimations()
            fillLayer.bounds = CGRect(x: 0, y: 0, width: width * min(max(fraction, 0), 1), height: height)
        }
        guard let secondsToEnd, secondsToEnd > 0.05, width > 0 else { return }
        let motion = CABasicAnimation(keyPath: "bounds.size.width")
        motion.fromValue = width * min(max(fraction, 0), 1)
        motion.toValue = width
        motion.duration = secondsToEnd
        motion.timingFunction = CAMediaTimingFunction(name: .linear)
        motion.fillMode = .forwards
        motion.isRemovedOnCompletion = false
        // 15 frames a second is plenty for a bar that moves a couple of points per second.
        motion.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 30, preferred: 15)
        fillLayer.add(motion, forKey: "progress")
    }

    /// Where the fill is on screen right now, as a fraction.
    private func currentFraction() -> Double {
        guard bounds.width > 0 else { return fraction }
        return Double((fillLayer.presentation() ?? fillLayer).bounds.width / bounds.width)
    }

    private func withoutAnimation(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}

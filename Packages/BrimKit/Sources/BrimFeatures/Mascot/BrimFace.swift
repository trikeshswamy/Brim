import SwiftUI
import BrimCore

/// Brim's face (your pick A, 2026-11-11: "Brim is the island"): two eyes on the island itself. No second character,
/// no image files: a few shapes drawn in code, so the eyes can follow your real pointer and it costs nothing to ship.
///
/// It is only alive (blinking, looking around) in short moments: the welcome, the hand-off after it, a tip. Asleep,
/// it's two still arcs: nothing animates, so the resting pill costs no CPU.
public struct BrimFace: View {
    public enum Mood: Equatable, Sendable {
        /// Closed eyes, curved down: resting.
        case asleep
        /// Open eyes with pupils that look where `gaze` points.
        case awake
        /// Closed eyes, curved up: pleased (you did the thing).
        case happy
        /// One open eye, one pleased: a switch flipped.
        case wink
    }

    let mood: Mood
    /// Where the pupils look: each axis −1…1 (x right, y down). Zero: straight ahead.
    var gaze: CGSize = .zero
    /// Mid-blink: the open eyes are squeezed shut for a moment.
    var blinking = false
    var eye = CGSize(width: 9, height: 11)
    var spacing: CGFloat = 8

    public init(mood: Mood, gaze: CGSize = .zero, blinking: Bool = false, eye: CGSize = CGSize(width: 9, height: 11),
                spacing: CGFloat = 8) {
        self.mood = mood
        self.gaze = gaze
        self.blinking = blinking
        self.eye = eye
        self.spacing = spacing
    }

    public var body: some View {
        HStack(spacing: spacing) {
            one(open: mood == .awake || mood == .wink, pleased: mood == .happy)
            one(open: mood == .awake, pleased: mood == .happy || mood == .wink)
        }
        .frame(height: eye.height)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: mood)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func one(open: Bool, pleased: Bool) -> some View {
        ZStack {
            if open {
                Capsule().fill(.white)
                    .overlay {
                        Circle().fill(.black)
                            .frame(width: eye.width * 0.56, height: eye.width * 0.56)
                            .offset(x: gaze.width * eye.width * 0.2, y: gaze.height * eye.height * 0.22)
                    }
                    .scaleEffect(y: blinking ? 0.12 : 1)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            } else {
                EyeArc(up: pleased)
                    .stroke(.white.opacity(pleased ? 1 : 0.8), style: StrokeStyle(lineWidth: max(1.6, eye.width * 0.2), lineCap: .round))
                    .frame(height: eye.height * 0.42)
                    .transition(.opacity)
            }
        }
        .frame(width: eye.width, height: eye.height)
    }
}

/// A closed eye: one curve, bowing down (asleep) or up (pleased).
nonisolated struct EyeArc: Shape {
    let up: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let edge = up ? rect.maxY : rect.minY
        let bow = up ? rect.minY - rect.height * 0.5 : rect.maxY + rect.height * 0.5
        path.move(to: CGPoint(x: rect.minX, y: edge))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: edge), control: CGPoint(x: rect.midX, y: bow))
        return path
    }
}

/// Brim's face, alive: it blinks now and then, and its eyes follow your pointer (15 looks a second, only while this
/// view is on screen: the welcome, the hand-off, a tip). Reduce Motion: no blinking, eyes straight ahead.
public struct LiveBrimFace: View {
    let mood: BrimFace.Mood
    /// The pointer, measured from the face's middle in points (x right, y down). Nil: look straight ahead.
    let pointer: (() -> CGPoint?)?
    var eye = CGSize(width: 9, height: 11)
    var spacing: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.offscreenRender) private var offscreenRender
    @State private var gaze: CGSize = .zero
    @State private var blinking = false

    public init(mood: BrimFace.Mood, pointer: (() -> CGPoint?)? = nil, eye: CGSize = CGSize(width: 9, height: 11),
                spacing: CGFloat = 8) {
        self.mood = mood
        self.pointer = pointer
        self.eye = eye
        self.spacing = spacing
    }

    public var body: some View {
        BrimFace(mood: mood, gaze: gaze, blinking: blinking, eye: eye, spacing: spacing)
            .task(id: reduceMotion) {
                guard !reduceMotion, !offscreenRender else { return }
                var untilBlink = Int.random(in: 30...60)  // looks until the next blink: 2–4 s
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(66))
                    let next = Self.gaze(toward: pointer?())
                    // Only when it moved enough to see: an idle pointer costs nothing.
                    if abs(next.width - gaze.width) > 0.04 || abs(next.height - gaze.height) > 0.04 {
                        withAnimation(.easeOut(duration: 0.12)) { gaze = next }
                    }
                    untilBlink -= 1
                    if untilBlink == 0 {
                        withAnimation(.easeIn(duration: 0.07)) { blinking = true }
                    } else if untilBlink < -1 {
                        withAnimation(.easeOut(duration: 0.1)) { blinking = false }
                        untilBlink = Int.random(in: 30...60)
                    }
                }
            }
    }

    /// Far away the eyes turn fully toward the pointer; within 120 pt they ease back to straight ahead.
    static func gaze(toward point: CGPoint?) -> CGSize {
        guard let point else { return .zero }
        let distance = max(120, (point.x * point.x + point.y * point.y).squareRoot())
        return CGSize(width: point.x / distance, height: point.y / distance)
    }
}

/// Brim asleep in its small resting pill (nothing plays): two still arcs. Awake while the hand-off points at it.
struct RestingBrimView: View {
    let awake: Bool
    let appearance: IslandAppearance

    var body: some View {
        let height = IslandMetrics.pillSize(appearance: appearance).height
        BrimFace(mood: awake ? .awake : .asleep, gaze: awake ? CGSize(width: 0, height: 0.8) : .zero,
                 eye: CGSize(width: height * 0.25, height: height * 0.31), spacing: height * 0.22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement()
            .accessibilityLabel("Brim, resting. Point at the top of the screen to open it.")
    }
}

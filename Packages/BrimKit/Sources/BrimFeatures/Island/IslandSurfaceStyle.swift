import SwiftUI
import BrimCore

/// The island's background for the chosen appearance (Settings → Island → Appearance).
/// - Liquid Glass: a floating rounded shape (`BrimGlass` picks the right glass for the macOS version).
/// - Black: a notch hanging from the top edge, with white content whatever the system look.
struct IslandSurfaceStyle: ViewModifier {
    let appearance: IslandAppearance
    let cornerRadius: CGFloat
    let shoulder: CGFloat
    /// Black only: 0 hangs from the edge (flat top); half the height floats as a capsule (the HUD).
    var topRadius: CGFloat = 0

    func body(content: Content) -> some View {
        switch appearance {
        case .liquidGlass:
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content
                .clipShape(shape)  // the HUD's fill must follow the island's corners
                .brimGlass(in: shape)
                .contentShape(shape)
        case .blackPill:
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content
                .environment(\.colorScheme, .dark)
                .background(Color.black, in: shape)
                .clipShape(shape)
                .contentShape(shape)
                .shadow(color: .black.opacity(0.22), radius: 10, y: 4)  // floats like the glass does
        case .black:
            let shape = NotchShape(bottomRadius: cornerRadius, shoulder: shoulder, topRadius: topRadius)
            content
                .environment(\.colorScheme, .dark)
                .padding(.horizontal, shoulder)  // the shoulders sit outside the island's width
                .background(Color.black, in: shape)
                .clipShape(shape)
                .contentShape(shape)
        }
    }
}

extension View {
    func islandSurface(_ appearance: IslandAppearance, for surface: IslandSurface,
                       geometry: IslandDisplayGeometry = .reference) -> some View {
        modifier(IslandSurfaceStyle(
            appearance: appearance,
            cornerRadius: IslandMetrics.cornerRadius(for: surface, appearance: appearance, geometry: geometry),
            shoulder: IslandMetrics.notchShoulder(for: surface, geometry: geometry),
            topRadius: IslandMetrics.notchTopRadius(for: surface, appearance: appearance, geometry: geometry)
        ))
    }
}

/// The notch on newer MacBooks: flat against the top edge, rounded bottom corners, and small inward
/// curves ("shoulders") where it meets the edge, so it looks like part of the screen's frame.
/// Both values animate, so the notch grows smoothly between the slim line, the pill, and the open island.
nonisolated struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var shoulder: CGFloat
    /// Above 0 the notch lets go of the edge: rounded top corners, no shoulders (the Black HUD floats).
    var topRadius: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(bottomRadius, shoulder), topRadius) }
        set {
            bottomRadius = newValue.first.first
            shoulder = newValue.first.second
            topRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        // Letting go of the edge: the shoulders give way to round top corners as the shape drops down.
        if topRadius > 0.5 {
            let body = rect.insetBy(dx: min(shoulder, rect.width / 4), dy: 0)
            let top = min(topRadius, body.height / 2, body.width / 2)
            let bottom = min(bottomRadius, body.height / 2, body.width / 2)
            return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                          bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
                .path(in: body)
        }
        let s = min(shoulder, rect.width / 4, rect.height / 2)
        let r = max(0, min(bottomRadius, rect.height - s, (rect.width - 2 * s) / 2))
        let left = rect.minX + s
        let right = rect.maxX - s
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + s), control: CGPoint(x: left, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: left, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.minY), radius: r)
        path.addLine(to: CGPoint(x: right, y: rect.minY + s))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

import AppKit
import SwiftUI

/// The island's surface. The only place that checks the macOS version for glass (architecture §13).
/// - macOS 26+: Liquid Glass, which also follows the macOS 27 glass-opacity slider.
/// - macOS 14–15: frosted material with a hairline edge and a soft shadow.
/// - Reduce Transparency: a solid background.
struct BrimGlass<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.offscreenRender) private var offscreenRender

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape)
        } else if offscreenRender {
            // Snapshot tests: an offscreen render drops glass views entirely, so a flat stand-in shows the layout.
            content
                .background(.white.opacity(0.14), in: shape)
                .overlay(shape.stroke(.white.opacity(0.35), lineWidth: 0.5))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        }
    }
}

extension View {
    func brimGlass<S: Shape>(in shape: S) -> some View {
        modifier(BrimGlass(shape: shape))
    }
}

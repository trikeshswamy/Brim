import SwiftUI
import Observation
import BrimCore

/// The hand-off after the welcome (your goal, 2026-11-11): the whole screen dims and one arrow points up at Brim,
/// so nobody wonders where it went. It ends when you point there (the island opens), click anywhere, or after 25 s.
/// Its window sits just under the island's, so Brim stays bright; it never takes a click from you.
@Observable
public final class HandoffModel {
    /// Dimmed and pointing; false while it fades away.
    public var showing = false
    public init() {}
}

public struct HandoffView: View {
    let model: HandoffModel
    /// How far below the top edge the island ends: the arrow starts under it.
    let islandBottom: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.offscreenRender) private var offscreenRender
    @State private var lifted = false

    public init(model: HandoffModel, islandBottom: CGFloat) {
        self.model = model
        self.islandBottom = islandBottom
    }

    public var body: some View {
        let on = model.showing || offscreenRender
        ZStack(alignment: .top) {
            Color.black.opacity(on ? 0.6 : 0)
            VStack(spacing: 10) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 30, weight: .semibold))
                    .offset(y: lifted ? -9 : 0)
                Text("Point here to open me.")
                    .font(.system(size: 17, weight: .semibold))
                Text("Or click anywhere to close this.")
                    .font(.system(size: 12)).opacity(0.65)
            }
            .foregroundStyle(.white)
            .padding(.top, islandBottom + 18)
            .opacity(on ? 1 : 0)
            .offset(y: on ? 0 : 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.35), value: on)
        .onChange(of: model.showing, initial: true) { _, showing in
            guard showing, !reduceMotion else { lifted = false; return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { lifted = true }
        }
        .accessibilityElement()
        .accessibilityLabel("Brim is at the top of your screen. Point there to open it.")
    }
}

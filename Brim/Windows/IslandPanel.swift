import AppKit
import SwiftUI

/// The borderless, see-through window the island is drawn in.
/// Floats above the menu bar on every Space and never takes keyboard focus from your app.
final class IslandPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar                  // 25: above the menu bar (24), proven in the spike
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                   // SwiftUI draws the island's own shadow
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true           // the window controller turns this on only while expanded
        allowsToolTipsWhenApplicationIsInactive = true  // Brim is never the active app; without this no hover hint shows
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on a button work even though Brim is never the active app.
/// Without this, macOS would treat the first click as "focus this window" and drop it.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

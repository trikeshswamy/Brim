import AppKit

/// An invisible window whose only job is to notice the pointer (and clicks) at the top-center.
/// Hidden island: a 240 × 2 pt strip at the top edge. Compact island: it grows to cover the pill.
final class HoverStripWindow: NSPanel {
    var onEnter: () -> Void = {}
    var onMove: (NSEvent) -> Void = { _ in }
    var onExit: () -> Void = {}
    /// Where the click landed, in the strip's own coordinates (the calendar reminder's Join end is clickable).
    var onClick: (NSPoint) -> Void = { _ in }
    /// A right-click (or Control-click) on the pill: its shortcuts menu.
    var onRightClick: (NSEvent) -> Void = { _ in }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)  // just above the island
        isOpaque = false
        // 1% black: invisible to you, but not fully transparent, so macOS always routes the pointer to it.
        backgroundColor = NSColor(white: 0, alpha: 0.01)
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true  // needed for "rest still" and "push up" detection
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = StripView()
        view.owner = self
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func place(_ frame: NSRect) {
        guard frame != self.frame else { return }
        setFrame(frame, display: false)
    }
}

private final class StripView: NSView {
    weak var owner: HoverStripWindow?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // .inVisibleRect: the area follows the view's size automatically when the strip is resized.
        // .mouseMoved: movement events arrive only while the pointer is inside this small strip.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    override func mouseEntered(with event: NSEvent) { owner?.onEnter() }
    override func mouseMoved(with event: NSEvent) { owner?.onMove(event) }
    override func mouseExited(with event: NSEvent) { owner?.onExit() }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return owner?.onRightClick(event) ?? () }  // Control-click, the Mac way
        owner?.onClick(convert(event.locationInWindow, from: nil))
    }
    override func rightMouseDown(with event: NSEvent) { owner?.onRightClick(event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

import AppKit
import SwiftUI
import BrimCore

extension View {
    /// Calls `action` with each scroll's vertical movement, in points, while the pointer is over this view: trackpad
    /// scrolls with their glide after a flick, and mouse-wheel notches (`LyricsBrowse.points`). A positive value moves
    /// content down, as macOS reports it (your natural-scrolling setting already applied).
    ///
    /// The same AppKit listener as `onSidewaysPaging`: SwiftUI has no scroll wheel on the Mac outside a scroll view, so a
    /// small view hears its own window's scroll events and never takes clicks. Offscreen renders get nothing.
    func onScrollWheel(perform action: @escaping (CGFloat) -> Void) -> some View {
        modifier(ScrollWheelModifier(action: action))
    }
}

private struct ScrollWheelModifier: ViewModifier {
    let action: (CGFloat) -> Void
    @Environment(\.offscreenRender) private var offscreenRender

    func body(content: Content) -> some View {
        if offscreenRender {
            content
        } else {
            content.background(WheelReader(action: action))
        }
    }
}

private struct WheelReader: NSViewRepresentable {
    let action: (CGFloat) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.action = action
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.action = action
    }

    static func dismantleNSView(_ view: ReaderView, coordinator: ()) {
        view.stopListening()
    }

    final class ReaderView: NSView {
        var action: ((CGFloat) -> Void)?
        private var monitor: Any?

        /// Clicks and hovering pass through to the lines drawn above.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopListening()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.scrolled(event) }
                return event
            }
        }

        func stopListening() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func scrolled(_ event: NSEvent) {
            guard event.window === window, event.scrollingDeltaY != 0,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            action?(LyricsBrowse.points(event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas))
        }
    }
}

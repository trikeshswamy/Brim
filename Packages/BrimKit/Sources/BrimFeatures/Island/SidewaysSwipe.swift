import AppKit
import SwiftUI
import BrimCore

extension View {
    /// A two-finger sideways swipe that starts over this view, reported as it happens (your pick, 2026-11-16: the
    /// pair beside the controls follows your fingers). `changed`: how far the fingers have moved sideways (points,
    /// right is +), from the moment the swipe is clearly sideways. `ended`: the same, and their speed as they lifted
    /// (points a second, right is +); a cancelled swipe ends at 0. Up-and-down swipes are left alone.
    func onSidewaysPaging(changed: @escaping (Double) -> Void, ended: @escaping (Double, Double) -> Void) -> some View {
        modifier(SidewaysPagingModifier(changed: changed, ended: ended))
    }
}

private struct SidewaysPagingModifier: ViewModifier {
    let changed: (Double) -> Void
    let ended: (Double, Double) -> Void
    @Environment(\.offscreenRender) private var offscreenRender

    func body(content: Content) -> some View {
        if offscreenRender {
            content
        } else {
            content.background(PagingReader(changed: changed, ended: ended))
        }
    }
}

private struct PagingReader: NSViewRepresentable {
    let changed: (Double) -> Void
    let ended: (Double, Double) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.changed = changed
        view.ended = ended
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.changed = changed
        view.ended = ended
    }

    static func dismantleNSView(_ view: ReaderView, coordinator: ()) {
        view.stopListening()
    }

    final class ReaderView: NSView {
        var changed: ((Double) -> Void)?
        var ended: ((Double, Double) -> Void)?
        private var monitor: Any?
        /// The swipe that began over this view: finger travel, and whether it's sideways (nil: not decided yet).
        private var travel: (dx: Double, dy: Double)?
        private var sideways: Bool?
        /// Recent finger positions, for the speed as they lift.
        private var recent: [(time: TimeInterval, dx: Double)] = []

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
            if sideways == true { ended?(0, 0) }
            travel = nil
            sideways = nil
        }

        private func scrolled(_ event: NSEvent) {
            guard event.window === window, event.momentumPhase.isEmpty else { return }
            if event.phase == .began {
                travel = bounds.contains(convert(event.locationInWindow, from: nil)) ? (0, 0) : nil
                sideways = nil
                recent = []
            }
            guard var moved = travel else { return }
            // Where the fingers went: with natural scrolling the deltas already follow them; without, they're reversed.
            let flip: Double = event.isDirectionInvertedFromDevice ? 1 : -1
            moved.dx += Double(event.scrollingDeltaX) * flip
            moved.dy += Double(event.scrollingDeltaY)
            travel = moved
            if sideways == nil, hypot(moved.dx, moved.dy) >= 6 {
                sideways = abs(moved.dx) > 1.5 * abs(moved.dy)
            }
            if sideways == true {
                recent.append((event.timestamp, moved.dx))
                recent.removeAll { event.timestamp - $0.time > 0.08 }
            }
            switch event.phase {
            case .ended, .cancelled:
                if sideways == true {
                    var speed = 0.0
                    if let first = recent.first, let last = recent.last, last.time - first.time > 0.005 {
                        speed = (last.dx - first.dx) / (last.time - first.time)
                    }
                    ended?(event.phase == .ended ? moved.dx : 0, event.phase == .ended ? speed : 0)
                }
                travel = nil
                sideways = nil
            default:
                if sideways == true { changed?(moved.dx) }
            }
        }
    }
}

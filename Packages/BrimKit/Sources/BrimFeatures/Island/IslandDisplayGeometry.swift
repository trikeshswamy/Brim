import CoreGraphics
import Observation

/// The display facts that affect the island's layout.
///
/// The reference values are only used by previews, tests, and debug benches. The live app replaces them with
/// values read from AppKit's `NSScreen` geometry before the island is shown.
public struct IslandDisplayGeometry: Equatable, Sendable {
    public var screenSize: CGSize
    /// The width of the camera-housing gap in screen points, when macOS reports one.
    public var notchWidth: CGFloat?
    /// The top safe-area inset reported by macOS, in screen points.
    public var topSafeInset: CGFloat
    public var backingScale: CGFloat

    public init(screenSize: CGSize = CGSize(width: 1440, height: 900), notchWidth: CGFloat? = nil,
                topSafeInset: CGFloat = 0, backingScale: CGFloat = 2) {
        self.screenSize = screenSize
        self.notchWidth = notchWidth
        self.topSafeInset = topSafeInset
        self.backingScale = backingScale
    }

    public static let reference = IslandDisplayGeometry(notchWidth: 185)

    public var isNotched: Bool { notchWidth != nil }

    /// The safe vertical offset used for MVP placement. A notched display reserves its camera-housing band;
    /// a non-notched display keeps the existing top-edge behavior.
    public var islandTopInset: CGFloat {
        isNotched ? max(0, topSafeInset) : 0
    }

    /// The Black appearance follows the reported notch width. The fallback keeps existing previews stable when no
    /// live screen is available.
    public var blackPillWidth: CGFloat {
        max(128, notchWidth ?? 185)
    }

    /// Open content should never be wider than the screen's usable top area. Current MacBooks all have ample room for
    /// the design width; the lower bound protects the layout on a small or heavily scaled display.
    public var expandedWidth: CGFloat {
        min(380, max(280, screenSize.width - 48))  // 380 (was 420): closer to Apple's island proportions (your pick, 2026-10-30)
    }
}

/// Shared by the AppKit window controller and the SwiftUI island view. Updating `value` causes the view to recompute
/// its metrics without rebuilding the window or interrupting the island coordinator.
@Observable
public final class IslandDisplayGeometryStore {
    public var value: IslandDisplayGeometry

    public init(_ value: IslandDisplayGeometry = .reference) {
        self.value = value
    }
}

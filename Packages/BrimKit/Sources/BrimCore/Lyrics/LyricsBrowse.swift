import CoreGraphics
import Foundation

/// Scrolling through the full-screen lyrics (your Apple Music video, 2026-10-01; 0.18.1): while you scroll, the list
/// stops following the song and every line is sharp; `returnAfter` seconds after your last scroll it glides back to the
/// line being sung. Pure, so tested.
public enum LyricsBrowse {
    /// How long after your last scroll the list goes back to following the song.
    public static let returnAfter: TimeInterval = 3

    /// Where the list may be scrolled to. `anchor` is the current line's place (30% from the top); `lastTop` is where
    /// the last line starts in the list. The first line can come down to the anchor and the last line up to it, and no
    /// further, so there's always a line where your eyes expect the song to be.
    public static func clamped(_ shift: CGFloat, anchor: CGFloat, lastTop: CGFloat) -> CGFloat {
        min(max(shift, anchor - lastTop), anchor)
    }

    /// A scroll in points: a trackpad reports points already; a mouse wheel reports notches.
    public static func points(_ delta: CGFloat, precise: Bool) -> CGFloat {
        precise ? delta : delta * notch
    }

    /// One mouse-wheel notch, in points (about a line of lyrics' gap).
    public static let notch: CGFloat = 24
}

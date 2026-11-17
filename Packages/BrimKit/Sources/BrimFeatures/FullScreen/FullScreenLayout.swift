import CoreGraphics

/// Where and how big the full-screen player draws on this screen: Apple Music's layout, measured.
///
/// Apple Music splits the screen in two halves (your screenshots, 2026-11-14 on a 1920 × 1080 TV and 2026-11-16 on
/// the 1440 × 900 Mac): the cover, title and controls sit centred in the left half (at a quarter of the width), and
/// the lyrics start just right of the middle (51% of the width) and run to about 94%. Their sizes follow the width:
/// lyrics ≈ 2.6% of it (38 pt on the Mac, 50 on the TV), the controls column 28% (403 and 538 pt). The cover stays
/// about 400 pt (403 on the Mac, 392 on the TV).
///
/// Before 2026-11-16 Brim centred one block (cover, gap, lyrics) in the middle with 34 pt lyrics, so on the Mac it
/// looked small and in the middle next to Apple's (your report).
struct FullScreenLayout: Equatable {
    /// What the sizes follow: the width, but no more than a 16:9 screen of this height, so a very wide, short screen
    /// doesn't get lyrics too tall for it.
    let unit: CGFloat
    let artSize: CGFloat
    /// The left side: cover, title, progress and controls (the cover sits centred in it).
    let columnWidth: CGFloat
    /// The middle of the left side, from the left edge, while the lyrics or queue show (alone, it's centred).
    let columnCenterX: CGFloat
    /// The right side's left edge (lyrics or queue), from the screen's left edge.
    let sideX: CGFloat
    let lyricsWidth: CGFloat
    let lyricsSize: CGFloat
    /// Between one lyric line and the next.
    let lyricsSpacing: CGFloat
    /// Between the buttons in the controls row, so they spread across a wider column like Apple's.
    let controlSpacing: CGFloat

    init(size: CGSize) {
        let unit = min(size.width, size.height * 16 / 9)
        self.unit = unit
        columnWidth = (unit * 0.28).rounded()
        artSize = min(columnWidth, (size.height * 0.448).rounded(), 404)
        columnCenterX = size.width * 0.25
        sideX = (size.width * 0.513).rounded()
        // To 94% of the width at most, so a long line never touches the edge.
        lyricsWidth = min((unit * 0.427).rounded(), size.width * 0.94 - sideX)
        lyricsSize = (unit * 0.0263 * 2).rounded() / 2
        lyricsSpacing = (lyricsSize * 1.24).rounded()
        controlSpacing = 40 + max(0, columnWidth - 403) * 30 / 135
    }

    /// For the lyrics' other texts ("Finding lyrics…", plain lyrics, "No lyrics for this song yet."): they grow with them.
    var textScale: CGFloat { lyricsSize / 34 }
}

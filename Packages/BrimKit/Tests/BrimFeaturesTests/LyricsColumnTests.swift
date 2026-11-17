import SwiftUI
import Testing
@testable import BrimFeatures

/// The full-screen lyrics column keeps the current line 30% from the top, so every line change must move the lines
/// by exactly the line that left plus the gap (0.13.3: they moved only the gap, because the heights were read from
/// an old copy; the view side of that is in `LyricsColumn.synced`, measured with `--bench-capture`).
struct LyricsColumnTests {
    let spacing: CGFloat = 26
    /// Two short lines (two text lines each) and a long one (four), like the bench song.
    let heights: [Int: CGFloat] = [0: 70, 1: 70, 2: 140, 3: 70]

    @Test func aLineStartsBelowTheLinesAndGapsAboveIt() {
        #expect(LyricsColumn.top(of: 0, heights: heights, spacing: spacing) == 0)
        #expect(LyricsColumn.top(of: 1, heights: heights, spacing: spacing) == 96)
        #expect(LyricsColumn.top(of: 3, heights: heights, spacing: spacing) == 358)
    }

    @Test func eachLineChangeMovesByTheLineThatLeft() {
        for current in 0..<3 {
            let move = LyricsColumn.top(of: current + 1, heights: heights, spacing: spacing)
                - LyricsColumn.top(of: current, heights: heights, spacing: spacing)
            #expect(move == heights[current]! + spacing)
        }
    }

    @Test func onlyTheLinesOnScreenAnimate() {
        #expect(LyricsColumn.motion(distance: -1, reduceMotion: false) != nil)  // the line leaving
        #expect(LyricsColumn.motion(distance: 8, reduceMotion: false) != nil)
        #expect(LyricsColumn.motion(distance: -4, reduceMotion: false) == nil)
        #expect(LyricsColumn.motion(distance: 9, reduceMotion: false) == nil)
        #expect(LyricsColumn.motion(distance: 30, reduceMotion: true) != nil)   // Reduce Motion: a short glide, all lines
    }
}

import Foundation
import Testing
@testable import BrimCore

/// Real word timing (enhanced LRC, `<mm:ss.xx>` before each word): used when LRCLIB has it, else the estimate.
struct WordTimingTests {
    @Test func tagsAreReadAndRemovedFromTheText() {
        let lines = LRCParser.parse("[00:10.00]<00:10.00>one <00:11.00>two <00:12.00>")
        #expect(lines.first?.text == "one two")
        #expect(lines.first?.marks == [WordMark(letter: 0, time: 10), WordMark(letter: 4, time: 11),
                                       WordMark(letter: 7, time: 12)])
    }

    @Test func plainLinesHaveNoMarksAndAStrayBracketStaysText() {
        #expect(LRCParser.parse("[00:01.00]a <b> c").first?.text == "a <b> c")
        #expect(LRCParser.parse("[00:01.00]plain").first?.marks == [])
    }

    @Test func aRepeatedLineMovesItsWordTimes() {
        let lines = LRCParser.parse("[00:10.00][01:10.00]<00:10.00>hey <00:10.50>you")
        #expect(lines[1].marks.first?.time == 70)
    }

    @Test func theSweepFollowsTheWords() {
        let marks = [WordMark(letter: 0, time: 10), WordMark(letter: 4, time: 11), WordMark(letter: 7, time: 12)]
        // Waiting before the first word.
        #expect(LyricSweep.timed(marks: marks, letters: 7, start: 9, nextStart: 15, position: 9.5).progress == 0)
        // Halfway through "one ": 2 of 7 letters, and the pace changes at 11 s.
        let mid = LyricSweep.timed(marks: marks, letters: 7, start: 9, nextStart: 15, position: 10.5)
        #expect(abs(mid.progress - 2.0 / 7) < 0.0001)
        #expect(mid.until == 11)
        // After the end mark: done and still.
        #expect(LyricSweep.timed(marks: marks, letters: 7, start: 9, nextStart: 15, position: 13).progress == 1)
    }
}

/// LRCLIB's newer `lyricsfile`: timing kept only there (many non-English songs, 2026-11-09).
struct LyricsFileTests {
    private let file = """
    version: '1.0'
    metadata:
      title: Song
    lines:
    - text: First line
      start_ms: 7360
      end_ms: 9870
    - text: 'It''s ਪੱਕੀ'
      start_ms: 12320
      end_ms: 15260
    - text: "Quoted \\"one\\""
      start_ms: 15260
    """

    @Test func readsLinesAndTheirStarts() {
        let lines = LyricsFile.lines(from: file)
        #expect(lines.map(\.text) == ["First line", "It's ਪੱਕੀ", #"Quoted "one""#])
        #expect(lines.first?.time == 7.36)
    }

    @Test func aRecordWithOnlyALyricsfileIsTimed() throws {
        let reply = try JSONSerialization.data(withJSONObject: ["syncedLyrics": NSNull(), "plainLyrics": "First line", "lyricsfile": file])
        guard case .found(.synced(let lines)) = LRCLIBReply.decode(reply) else { Issue.record("not timed"); return }
        #expect(lines.count == 3)
    }
}

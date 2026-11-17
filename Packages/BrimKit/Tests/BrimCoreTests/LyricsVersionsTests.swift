import Foundation
import Testing
@testable import BrimCore

struct LyricsVersionsTests {
    /// Four uploads of one song: a copy of the first, a different timing, and another cut (10 s longer).
    private let reply = Data("""
    [
      {"id": 1, "duration": 214.0, "syncedLyrics": "[00:04.70] Hey!\\n[00:06.93] We drove all night"},
      {"id": 2, "duration": 214.0, "syncedLyrics": "[00:04.70] Hey!\\n[00:06.93] We drove all night"},
      {"id": 3, "duration": 213.571, "syncedLyrics": "[00:04.92] Woo\\n[00:06.50] We drove all night"},
      {"id": 4, "duration": 224.0, "syncedLyrics": "[00:14.00] Hey!\\n[00:16.00] We drove all night"},
      {"id": 5, "duration": 214.0, "plainLyrics": "no timing here"}
    ]
    """.utf8)

    @Test func keepsDistinctTimingsAtTheSongsLength() throws {
        let versions = try #require(LRCLIBVersions.decode(reply, duration: 213.6, current: nil))
        #expect(versions.map(\.id) == [1, 3])  // 2 is a copy of 1, 4 is another cut, 5 has no timing
    }

    @Test func theVersionInUseComesFirst() throws {
        let current = try #require(LyricsVersion(record: Data(#"{"id": 3, "syncedLyrics": "[00:04.92] Woo\n[00:06.50] We drove all night"}"#.utf8)))
        let versions = try #require(LRCLIBVersions.decode(reply, duration: 213.6, current: current))
        #expect(versions.map(\.id) == [3, 1])
    }

    @Test func aVersionsRecordReadsBackLikeALookup() throws {
        let versions = try #require(LRCLIBVersions.decode(reply, duration: 214, current: nil))
        #expect(LRCLIBReply.decode(versions[1].record) == .found(.synced(versions[1].lines)))
    }

    @Test func copiesFoldAndTheRestGoEarliestFirst() throws {
        let second = Data("""
        [
          {"id": 6, "duration": 214.0, "syncedLyrics": "[00:04.92] Woo\\n[00:06.50] We drove all night"},
          {"id": 7, "duration": 214.0, "syncedLyrics": "[00:05.10] Woo\\n[00:07.00] We drove all night"},
          {"id": 3, "duration": 213.571, "syncedLyrics": "[00:04.92] Woo\\n[00:06.50] We drove all night"}
        ]
        """.utf8)
        let current = try #require(LyricsVersion(record: Data(#"{"id": 1, "syncedLyrics": "[00:04.70] Hey!\n[00:06.93] We drove all night"}"#.utf8)))
        let versions = try #require(LRCLIBVersions.decode([reply, second], duration: 213.6, current: current))
        // 6 is a copy of 3; 3 found twice counts once. Then earliest first: 3 (−0.43 s), 7 (+0.07 s).
        #expect(versions.map(\.id) == [1, 3, 7])
    }

    @Test func versionsGoFromEarliestToLatest() throws {
        func upload(_ id: Int, _ start: Double) -> String {
            #"{"id": \#(id), "duration": 214.0, "syncedLyrics": "[00:\#(String(format: "%05.2f", start))] one\n[00:\#(String(format: "%05.2f", start + 3))] two\n[00:\#(String(format: "%05.2f", start + 6))] three"}"#
        }
        // Compared with the current one (10, at 4.7 s): 16 is 0.7 s earlier; 15 +0.2; 11 +1.6; 13 +1.7; 12 +1.8; 14 +4.3.
        let reply = Data("[\(upload(15, 4.9)), \(upload(14, 9)), \(upload(11, 6.3)), \(upload(12, 6.5)), \(upload(13, 6.4)), \(upload(16, 4.0))]".utf8)
        let current = try #require(LyricsVersion(record: Data(upload(10, 4.7).utf8)))
        let versions = try #require(LRCLIBVersions.decode([reply], duration: 214, current: current))
        #expect(versions.map(\.id) == [10, 16, 15, 11, 13, 12, 14])
    }

    @Test func linesMatchByMostlyTheSameWords() {
        let a = [LyricLine(time: 4.7, text: "Hey!"), LyricLine(time: 6.93, text: "We drove all night"),
                 LyricLine(time: 12.21, text: "And the road was ours, darlin'")]
        let b = [LyricLine(time: 4.9, text: "hey"), LyricLine(time: 7.0, text: "we drove all night"),
                 LyricLine(time: 12.54, text: "And the road was ours, darling")]
        let comparison = LRCLIBVersions.compare(a, b)
        #expect(comparison.coverage == 1)
        #expect(abs((comparison.shift ?? 99) - -0.2) < 0.001)   // median of −0.2, −0.07, −0.33
    }

    /// The solo "Easy" and the remix share a length but not a second verse: the rest still lines up.
    @Test func aChangedVerseDoesntDerailTheRest() {
        let remix = [LyricLine(time: 10, text: "first line here"), LyricLine(time: 20, text: "I'm not a saint so just"),
                     LyricLine(time: 30, text: "the chorus comes back")]
        let solo = [LyricLine(time: 9.6, text: "first line here"), LyricLine(time: 19.6, text: "What's left of the dance"),
                    LyricLine(time: 29.6, text: "the chorus comes back")]
        let comparison = LRCLIBVersions.compare(solo, remix)
        #expect(abs(comparison.coverage - 2.0 / 3.0) < 0.001)
        #expect(abs((comparison.shift ?? 99) - -0.4) < 0.001)
    }

    @Test func aSongBySeveralArtistsIsAlsoSearchedUnderItsLead() {
        #expect(LRCLIBVersions.searchArtists(for: "Nora Vale & Milo Hart") == ["Nora Vale & Milo Hart", "Nora Vale"])
        #expect(LRCLIBVersions.searchArtists(for: "Nora Vale, Milo Hart & Ivy Lane") == ["Nora Vale, Milo Hart & Ivy Lane", "Nora Vale"])
        #expect(LRCLIBVersions.searchArtists(for: "Nora Vale feat. Milo Hart") == ["Nora Vale feat. Milo Hart", "Nora Vale"])
        #expect(LRCLIBVersions.searchArtists(for: "Nora Vale") == ["Nora Vale"])
    }

    @Test func extrasInTheTitleAddABareSearch() {
        #expect(LRCLIBVersions.searchTitles(for: "Easy (with June Avery feat. Theo Marsh)")
                == ["Easy (with June Avery feat. Theo Marsh)", "Easy"])
        #expect(LRCLIBVersions.searchTitles(for: "Steal My Thunder (feat. Tucker Wetmore) [From Twisters: The Album]")
                == ["Steal My Thunder (feat. Tucker Wetmore) [From Twisters: The Album]", "Steal My Thunder"])
        #expect(LRCLIBVersions.searchTitles(for: "Dog Days Are Over - 2010 Remaster")
                == ["Dog Days Are Over - 2010 Remaster", "Dog Days Are Over"])
        #expect(LRCLIBVersions.searchTitles(for: "History") == ["History"])
    }

    @Test func unreadableReplyIsNil() {
        #expect(LRCLIBVersions.decode(Data("oops".utf8), duration: 200, current: nil) == nil)
    }

    @Test func shiftingMovesEveryLine() {
        let lyrics = Lyrics.synced([LyricLine(time: 5, text: "a"), LyricLine(time: 10, text: "b")])
        #expect(lyrics.shifted(by: -0.5) == .synced([LyricLine(time: 4.5, text: "a"), LyricLine(time: 9.5, text: "b")]))
        #expect(Lyrics.plain("x").shifted(by: 1) == .plain("x"))
    }
}

struct LyricSweepTests {
    @Test func sweepFinishesBeforeTheNextLine() {
        // 40 letters, next line 4 s later: 90% of the gap.
        #expect(abs(LyricSweep.duration(start: 10, nextStart: 14, letters: 40) - 3.6) < 0.0001)
    }

    @Test func aLongPauseDoesntStretchTheSweep() {
        // 20 letters, next line 30 s later: 20 / 5 = 4 s, not 27.
        #expect(LyricSweep.duration(start: 0, nextStart: 30, letters: 20) == 4)
    }

    @Test func progressIsClampedToTheLine() {
        #expect(LyricSweep.progress(position: 9, start: 10, nextStart: 14, letters: 40) == 0)
        #expect(LyricSweep.progress(position: 20, start: 10, nextStart: 14, letters: 40) == 1)
    }

}

struct RescueRulesTests {
    @Test func onlySameRecordingExtrasAreStripped() {
        #expect(LRCLIBVersions.sameRecordingTitle(for: "Dog Days Are Over - 2010 Remaster") == "Dog Days Are Over")
        #expect(LRCLIBVersions.sameRecordingTitle(for: "Heroes (Remastered 2017)") == "Heroes")
        #expect(LRCLIBVersions.sameRecordingTitle(for: "Steal My Thunder (feat. Tucker Wetmore) [From Twisters: The Album]")
                == "Steal My Thunder (feat. Tucker Wetmore)")   // the feature stays: it could be another recording
        #expect(LRCLIBVersions.sameRecordingTitle(for: "Song - Bonus Track") == "Song")
        #expect(LRCLIBVersions.sameRecordingTitle(for: "Easy (with June Avery feat. Theo Marsh)") == nil)
        #expect(LRCLIBVersions.sameRecordingTitle(for: "Song (Live)") == nil)
        #expect(LRCLIBVersions.sameRecordingTitle(for: "History") == nil)
    }

    private let replies = [Data("""
    [
      {"id": 1, "duration": 300.0, "syncedLyrics": "[00:05.00] far too long"},
      {"id": 2, "duration": 200.0, "plainLyrics": "hello there\\nsecond line"},
      {"id": 3, "duration": 201.0, "syncedLyrics": "[00:05.00] hello there\\n[00:09.00] second line"}
    ]
    """.utf8)]

    @Test func timedLyricsAtTheRightLengthWin() throws {
        let record = try #require(LRCLIBVersions.bestRecord(in: replies, duration: 200))
        #expect(LyricsVersion(record: record)?.id == 3)
    }

    @Test func untimedOnlyWhenNothingTimedFits() throws {
        let plainOnly = [Data(#"[{"id": 2, "duration": 200.0, "plainLyrics": "hello there"}]"#.utf8)]
        let record = try #require(LRCLIBVersions.bestRecord(in: plainOnly, duration: 200))
        #expect(LRCLIBReply.decode(record) == .found(.plain("hello there")))
    }

    @Test func anUpgradeMustHaveTheSameWords() {
        #expect(LRCLIBVersions.bestRecord(in: replies, duration: 200, words: "hello there\nsecond line") != nil)
        #expect(LRCLIBVersions.bestRecord(in: replies, duration: 200, words: "completely different\nsong words") == nil)
    }
}

struct SweepPlanTests {
    private let anchor = Date(timeIntervalSince1970: 1_000)

    @Test func theClockRunsOnlyWhilePlaying() {
        let playing = SweepClock(line: 0, progress: 0.25, anchor: anchor, duration: 4, playing: true)
        #expect(playing.progress(at: anchor.addingTimeInterval(1)) == 0.5)
        #expect(playing.progress(at: anchor.addingTimeInterval(10)) == 1)
        let paused = SweepClock(line: 0, progress: 0.25, anchor: anchor, duration: 4, playing: false)
        #expect(paused.progress(at: anchor.addingTimeInterval(10)) == 0.25)
    }

    @Test func findsTwoVisualLinesAndIgnoresTheGapInside() {
        // 10 × 12 px: line 1 rows 1–4 (with a 1-row gap, like an "i" dot), blank 5–8, line 2 rows 9–10.
        var alpha = [UInt8](repeating: 0, count: 10 * 12)
        for x in 2...7 { alpha[1 * 10 + x] = 255 }
        for y in 3...4 { for x in 1...8 { alpha[y * 10 + x] = 255 } }
        for y in 9...10 { for x in 0...5 { alpha[y * 10 + x] = 255 } }
        let bands = SweepBands.detect(alpha: alpha, width: 10, height: 12)
        #expect(bands == [CGRect(x: 1, y: 1, width: 8, height: 4), CGRect(x: 0, y: 9, width: 6, height: 2)])
    }

    @Test func aDotOnItsOwnRowJoinsItsLine() {
        var alpha = [UInt8](repeating: 0, count: 10 * 20)
        alpha[0 * 10 + 4] = 255                                     // a dot, then 5 blank rows
        for y in 6...15 { for x in 1...8 { alpha[y * 10 + x] = 255 } }
        let bands = SweepBands.detect(alpha: alpha, width: 10, height: 20)
        #expect(bands == [CGRect(x: 1, y: 0, width: 8, height: 16)])
    }

    @Test func theFrontCrossesLinesInReadingOrder() {
        // Two lines 90 and 40 wide, edge 10: lengths 100 + 50; a 3 s sweep at 50 points per second.
        let bands = [CGRect(x: 0, y: 0, width: 90, height: 30), CGRect(x: 0, y: 40, width: 40, height: 30)]
        let clock = SweepClock(line: 0, progress: 0.5, anchor: anchor, duration: 3, playing: true)
        let steps = SweepPlan.steps(for: bands, edge: 10, clock: clock, at: anchor)
        #expect(steps[0] == SweepStep(from: 75, to: 100, delay: 0, duration: 0.5))   // 75 of 100 done
        #expect(steps[1] == SweepStep(from: 0, to: 50, delay: 0.5, duration: 1))     // waits for line 1
    }

    /// The line arrives ~0.6 s into its time: its sweep starts over from the first letter then, ending on time.
    @Test func aLateStartSweepsFromTheFirstLetter() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let clock = SweepClock(line: 3, progress: 0, anchor: t0, duration: 2, playing: true)
        let late = clock.startingNow(t0.addingTimeInterval(0.6))
        #expect(late.progress(at: t0.addingTimeInterval(0.6)) == 0)       // nothing lit yet
        #expect(abs(late.duration - 1.4) < 0.0001)                         // ends when the first would have
        #expect(late.progress(at: t0.addingTimeInterval(2)) == 1)
    }

    @Test func pausedMeansStill() {
        let bands = [CGRect(x: 0, y: 0, width: 90, height: 30)]
        let clock = SweepClock(line: 0, progress: 0.2, anchor: anchor, duration: 3, playing: false)
        #expect(SweepPlan.steps(for: bands, edge: 10, clock: clock, at: anchor) == [SweepStep(from: 20, to: 100, delay: nil, duration: 0)])
    }
}

/// Another cut of the song (10 s or less apart): its timing when it has some, else only its words.
struct AnotherCutTests {
    @Test func nearLengthGivesTheClosestTimedCut() throws {
        let reply = try JSONSerialization.data(withJSONObject: [[
            "id": 1, "trackName": "You (Demo)", "duration": 164.0,
            "syncedLyrics": "[00:01.00]First line\n[00:05.00]Second line", "plainLyrics": NSNull(),
        ]])
        let record = try #require(LRCLIBVersions.bestRecord(in: [reply], duration: 158))
        let entry = try #require(try JSONSerialization.jsonObject(with: record) as? [String: Any])
        // The closest timed cut is used, timed (your report, 2026-11-10).
        #expect(entry["syncedLyrics"] as? String == "[00:01.00]First line\n[00:05.00]Second line")
        #expect(LRCLIBVersions.bestRecord(in: [reply], duration: 140) == nil)  // 24 s apart: another song
    }
}

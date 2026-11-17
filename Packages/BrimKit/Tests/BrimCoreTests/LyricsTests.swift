import Foundation
import Testing
@testable import BrimCore

struct LRCParserTests {
    @Test func readsEveryTimestampForm() {
        let lines = LRCParser.parse("""
        [00:01]one
        [00:02.5]two
        [00:03.25]three
        [00:04.125]four
        [01:05.00]five
        """)
        #expect(lines.map(\.time) == [1, 2.5, 3.25, 4.125, 65])
        #expect(lines.map(\.text) == ["one", "two", "three", "four", "five"])
    }

    @Test func oneLineWithSeveralStampsRepeats() {
        let lines = LRCParser.parse("[00:10.00][00:40.00]Chorus\n[00:20.00]Verse")
        #expect(lines == [LyricLine(time: 10, text: "Chorus"), LyricLine(time: 20, text: "Verse"),
                          LyricLine(time: 40, text: "Chorus")])
    }

    @Test func skipsMetadataAndAppliesOffset() {
        let lines = LRCParser.parse("""
        [ar:Artist]
        [ti:Title]
        [offset:+500]
        [00:10.00]Hello
        """)
        #expect(lines == [LyricLine(time: 9.5, text: "Hello")])  // +500 ms shows lines half a second earlier
    }

    @Test func keepsInstrumentalGapsAsEmptyLines() {
        let lines = LRCParser.parse("[00:05.00]Words\n[00:09.00]\n[00:15.00]More")
        #expect(lines.map(\.text) == ["Words", "", "More"])
    }

    @Test func ignoresBrokenLinesAndText() {
        #expect(LRCParser.parse("no stamps here\n[aa:bb]x\n[00:61.00]bad seconds").isEmpty)
    }
}

struct LyricsSyncTests {
    private let lyrics = Lyrics.synced([LyricLine(time: 5, text: "a"), LyricLine(time: 10, text: "b"),
                                        LyricLine(time: 15, text: "c")])

    @Test func currentLineFollowsThePosition() {
        #expect(lyrics.currentLineIndex(at: 0) == nil)     // before the first line
        #expect(lyrics.currentLineIndex(at: 5) == 0)       // exactly on a timestamp
        #expect(lyrics.currentLineIndex(at: 9.99) == 0)
        #expect(lyrics.currentLineIndex(at: 10) == 1)
        #expect(lyrics.currentLineIndex(at: 300) == 2)     // after the last line
    }

    @Test func nextLineTimeIsTheOnlyWakeUpNeeded() {
        #expect(lyrics.nextLineTime(after: 0) == 5)
        #expect(lyrics.nextLineTime(after: 5) == 10)
        #expect(lyrics.nextLineTime(after: 15) == nil)     // nothing left to schedule
        #expect(Lyrics.plain("words").nextLineTime(after: 0) == nil)
    }
}

struct LyricsLookupRulesTests {
    private func item(title: String = "Song", artist: String? = "Artist", duration: TimeInterval? = 200) -> NowPlaying {
        NowPlaying(title: title, artist: artist, isPlaying: true, duration: duration)
    }

    @Test func looksUpOrdinarySongs() {
        #expect(LyricsQuery(item()) != nil)
    }

    @Test func skipsPodcastsLongVideosAndMissingInfo() {
        #expect(LyricsQuery(item(duration: 15 * 60)) == nil)   // 15 minutes and over
        #expect(LyricsQuery(item(duration: nil)) == nil)
        #expect(LyricsQuery(item(artist: nil)) == nil)
        #expect(LyricsQuery(item(title: "")) == nil)
    }

    @Test func cacheKeyIgnoresCaseAndSubSecondLength() {
        let a = LyricsQuery(title: "Song", artist: "Artist", album: "Album", duration: 200.2)
        let b = LyricsQuery(title: "song", artist: "ARTIST", album: "album", duration: 199.8)
        #expect(a.cacheKey == b.cacheKey)
    }
}

struct LRCLIBReplyTests {
    private func reply(_ json: String) -> LyricsResult { LRCLIBReply.decode(Data(json.utf8)) }

    @Test func syncedLyricsWin() {
        let result = reply(#"{"instrumental":false,"plainLyrics":"Hello","syncedLyrics":"[00:01.00]Hello"}"#)
        #expect(result == .found(.synced([LyricLine(time: 1, text: "Hello")])))
    }

    @Test func plainWhenThereIsNoTiming() {
        #expect(reply(#"{"instrumental":false,"plainLyrics":"Hello","syncedLyrics":null}"#) == .found(.plain("Hello")))
    }

    @Test func instrumentalAndEmptyReplies() {
        #expect(reply(#"{"instrumental":true,"plainLyrics":null,"syncedLyrics":null}"#) == .found(.instrumental))
        #expect(reply(#"{"instrumental":false,"plainLyrics":"","syncedLyrics":""}"#) == .notFound)
        if case .failed = reply("not json") {} else { Issue.record("expected .failed") }
    }
}

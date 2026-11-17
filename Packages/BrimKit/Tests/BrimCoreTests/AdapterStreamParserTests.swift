import Foundation
import Testing
@testable import BrimCore

struct AdapterStreamParserTests {
    private let full = #"{"type":"data","diff":false,"payload":{"title":"Song","artist":"Artist","album":"Album","playing":false,"durationMicros":200000000,"elapsedTimeMicros":10000000,"timestampEpochMicros":1000000000000000,"bundleIdentifier":"com.spotify.client"}}"#

    @Test func fullPayloadThenDiffMerges() throws {
        let parser = AdapterStreamParser()
        guard case .item(let first) = parser.consume(line: full) else { Issue.record("expected item"); return }
        #expect(first.title == "Song")
        #expect(first.isPlaying == false)
        #expect(first.duration == 200)
        #expect(first.elapsed == 10)

        guard case .item(let second) = parser.consume(line: #"{"type":"data","diff":true,"payload":{"playing":true}}"#)
        else { Issue.record("expected item"); return }
        #expect(second.title == "Song")   // kept from the full payload
        #expect(second.isPlaying == true) // changed by the diff
    }

    @Test func nullInDiffRemovesField() {
        let parser = AdapterStreamParser()
        _ = parser.consume(line: full)
        guard case .item(let next) = parser.consume(line: #"{"type":"data","diff":true,"payload":{"album":null}}"#)
        else { Issue.record("expected item"); return }
        #expect(next.album == nil)
    }

    @Test func emptyPayloadMeansNothingPlaying() {
        let parser = AdapterStreamParser()
        #expect(parser.consume(line: #"{"type":"data","diff":false,"payload":{}}"#) == .nothingPlaying)
    }

    @Test func missingTitleMeansNothingPlaying() {
        let parser = AdapterStreamParser()
        #expect(parser.consume(line: #"{"type":"data","diff":false,"payload":{"artist":"A"}}"#) == .nothingPlaying)
    }

    @Test func garbageIsIgnored() {
        let parser = AdapterStreamParser()
        #expect(parser.consume(line: "not json") == .ignored)
        #expect(parser.consume(line: #"{"type":"log","payload":{}}"#) == .ignored)
    }

    @Test func artworkSurvivesDiffsUntilRemoved() {
        let parser = AdapterStreamParser()
        let bytes = Data([1, 2, 3])
        let withArt = #"{"type":"data","diff":false,"payload":{"title":"Song","artworkData":"\#(bytes.base64EncodedString())"}}"#
        guard case .item(let first) = parser.consume(line: withArt) else { Issue.record("expected item"); return }
        #expect(first.artwork == bytes)

        guard case .item(let second) = parser.consume(line: #"{"type":"data","diff":true,"payload":{"playing":true}}"#)
        else { Issue.record("expected item"); return }
        #expect(second.artwork == bytes)  // not re-sent, still there

        guard case .item(let third) = parser.consume(line: #"{"type":"data","diff":true,"payload":{"artworkData":null}}"#)
        else { Issue.record("expected item"); return }
        #expect(third.artwork == nil)
    }

    @Test func parentAppIsPreferredAsSource() {
        let parser = AdapterStreamParser()
        let line = #"{"type":"data","diff":false,"payload":{"title":"Video","bundleIdentifier":"com.apple.WebKit.GPU","parentApplicationBundleIdentifier":"com.apple.Safari"}}"#
        guard case .item(let item) = parser.consume(line: line) else { Issue.record("expected item"); return }
        #expect(item.sourceBundleIdentifier == "com.apple.Safari")
    }
}

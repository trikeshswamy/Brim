import AppKit
import Foundation
import Testing
@testable import BrimCore
@testable import BrimFeatures

/// History above Up Next: per app, a song joins once it played 5 s and the next one starts, the last 50 are kept, and
/// it's saved on your Mac.
@MainActor
struct HistoryStoreTests {
    private final class FakeHistory: HistoryService, HistoryFile, @unchecked Sendable {
        var saved: [String: [HistoryEntry]] = [:]
        var played: [String] = []
        func currentSongID(in player: ScriptablePlayer) async -> String? { nil }
        func play(_ entry: HistoryEntry, in player: ScriptablePlayer) async -> Bool { played.append(entry.title); return true }
        func load() -> [String: [HistoryEntry]] { saved }
        func save(_ history: [String: [HistoryEntry]]) { saved = history }
    }

    private func store() -> (HistoryStore, FakeHistory) {
        let nowPlaying = NowPlayingStore(service: FakeNowPlayingService(), island: IslandCoordinator())
        let fake = FakeHistory()
        return (HistoryStore(service: fake, file: fake, nowPlaying: nowPlaying), fake)
    }

    private func song(_ title: String, _ app: String, cover: Data? = nil) -> NowPlaying {
        NowPlaying(title: title, artist: "Milo Hart", bundleIdentifier: app, isPlaying: true, artwork: cover)
    }

    /// A one-colour cover, and the colour in the middle of a saved one (JPEG: close, not exact).
    private func cover(_ color: NSColor) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private func isRed(_ data: Data?) -> Bool {
        guard let data, let rep = NSBitmapImageRep(data: data), let c = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?
            .usingColorSpace(.deviceRGB) else { return false }
        return c.redComponent > 0.8 && c.blueComponent < 0.2
    }

    /// Your screenshot, 2026-11-16: each History row had the cover of the song before it. A new song's title arrives
    /// before its cover (the island keeps the last cover meanwhile); its row must still get its own cover.
    @Test func eachSongKeepsItsOwnCoverWhenTheCoverArrivesLate() {
        let (history, _) = store()
        let start = Date()
        history.follow(song("Red", "com.apple.Music", cover: cover(.red)), now: start)
        history.follow(song("Blue", "com.apple.Music"), now: start.addingTimeInterval(30))              // title first
        history.follow(song("Blue", "com.apple.Music", cover: cover(.blue)), now: start.addingTimeInterval(30.5))
        history.follow(song("Next", "com.apple.Music"), now: start.addingTimeInterval(60))
        let entries = history.entries(for: "com.apple.Music")
        #expect(entries.map(\.title) == ["Red", "Blue"])
        #expect(isRed(entries[0].cover))
        #expect(entries[1].cover != nil && !isRed(entries[1].cover))
    }

    @Test func aSongJoinsItsAppsHistoryWhenTheNextOneStarts() {
        let (history, fake) = store()
        let start = Date()
        history.follow(song("One", "com.apple.Music"), now: start)
        history.follow(song("Two", "com.apple.Music"), now: start.addingTimeInterval(30))
        #expect(history.entries(for: "com.apple.Music").map(\.title) == ["One"])  // "Two" is playing: not yet
        #expect(fake.saved["com.apple.Music"]?.count == 1)
        // Spotify keeps its own History.
        history.follow(song("Three", "com.spotify.client"), now: start.addingTimeInterval(60))
        history.follow(song("Four", "com.spotify.client"), now: start.addingTimeInterval(90))
        #expect(history.entries(for: "com.spotify.client").map(\.title) == ["Three"])
        #expect(history.entries(for: "com.apple.Music").map(\.title) == ["One", "Two"])
    }

    @Test func aSongSkippedWithinFiveSecondsIsntHistory() {
        let (history, _) = store()
        let start = Date()
        history.follow(song("Skipped", "com.apple.Music"), now: start)
        history.follow(song("Kept", "com.apple.Music"), now: start.addingTimeInterval(2))
        history.follow(song("Next", "com.apple.Music"), now: start.addingTimeInterval(40))
        #expect(history.entries(for: "com.apple.Music").map(\.title) == ["Kept"])
    }

    @Test func clearEmptiesOnlyThatApp() {
        let (history, fake) = store()
        let start = Date()
        for (i, app) in ["com.apple.Music", "com.spotify.client", "com.apple.Music"].enumerated() {
            history.follow(song("S\(i)", app), now: start.addingTimeInterval(Double(i) * 30))
        }
        history.clear(app: "com.apple.Music")
        #expect(history.entries(for: "com.apple.Music").isEmpty && fake.saved["com.spotify.client"]?.count == 1)
    }

    @Test func keepsTheLastFiftyAndNoRepeatsInARow() {
        var list: [HistoryEntry] = []
        for i in 0..<60 { list = PlayHistoryRules.adding(HistoryEntry(title: "S\(i)", artist: nil), to: list) }
        #expect(list.count == 50 && list.first?.title == "S10")
        #expect(PlayHistoryRules.adding(HistoryEntry(title: "S59", artist: nil), to: list).count == 50)
    }

    @Test func onlyRealSongIDsReachAScript() {
        #expect(PlayHistoryRules.isValidSongID("spotify:track:4uLU6hMCjMI75M1A2tKUQC", for: .spotify))
        #expect(!PlayHistoryRules.isValidSongID("spotify:track:\" & do shell script \"x", for: .spotify))
        #expect(PlayHistoryRules.isValidSongID("A1B2C3D4E5F60718", for: .music))
        #expect(!PlayHistoryRules.isValidSongID("A1B2\" whose", for: .music))
    }
}

import Foundation
import Testing
@testable import BrimCore
@testable import BrimFeatures

/// Tips: shown once each, counted as seen only when up long enough to read, skipped once you did the thing yourself.
@MainActor
struct TipsStoreTests {
    private func settings() -> IslandSettings {
        IslandSettings(defaults: UserDefaults(suiteName: testSuiteName("brim.tips"))!)
    }

    private func settle(_ store: TipsStore) async {
        for _ in 0..<50 where store.current == nil { await Task.yield() }
    }

    @Test func aTipReadIsNeverShownAgain() async {
        let settings = settings()
        var clock = Date(timeIntervalSince1970: 0)
        let store = TipsStore(settings: settings, delay: .zero, dwell: .seconds(60), now: { clock })
        store.islandOpened { TipsStore.Showing(page: .calendar, hasSong: false, lyricsShowing: false) }
        await settle(store)
        #expect(store.current == .menu)
        clock += 2
        store.islandClosed()
        #expect(store.current == nil && settings.tipsSeen == ["menu"])
        store.islandOpened { TipsStore.Showing(page: .calendar, hasSong: false, lyricsShowing: false) }
        await settle(store)
        #expect(store.current == nil)
    }

    @Test func aGlimpseDoesNotCount() async {
        let settings = settings()
        var clock = Date(timeIntervalSince1970: 0)
        let store = TipsStore(settings: settings, delay: .zero, dwell: .seconds(60), now: { clock })
        store.islandOpened { TipsStore.Showing(page: .calendar, hasSong: false, lyricsShowing: false) }
        await settle(store)
        clock += 0.5
        store.islandClosed()
        #expect(settings.tipsSeen.isEmpty)
    }

    @Test func doingItYourselfSkipsItsTip() async {
        let settings = settings()
        settings.tipsSeen = ["menu"]
        let store = TipsStore(settings: settings, delay: .zero, dwell: .seconds(60))
        store.learned(.cover)
        store.islandOpened { TipsStore.Showing(page: .music, hasSong: true, lyricsShowing: false) }
        await settle(store)
        #expect(store.current == .swipe)
    }

    /// While the island stays open the tips take turns (your report: the next came only after leaving Brim).
    @Test func tipsTakeTurnsWhileTheIslandStaysOpen() async throws {
        let settings = settings()
        let store = TipsStore(settings: settings, delay: .zero, dwell: .milliseconds(30))
        var lyricsOn = false
        store.islandOpened { TipsStore.Showing(page: .music, hasSong: true, lyricsShowing: lyricsOn) }
        var seen: [Tip] = []
        for _ in 0..<400 where seen.count < 3 {
            if let tip = store.current, seen.last != tip { seen.append(tip) }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(seen == [.menu, .cover, .swipe])
        // Lyrics turned on with the island still open: its tip comes without closing it.
        lyricsOn = true
        for _ in 0..<400 where store.current != .lyrics { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.current == .lyrics)
        store.islandClosed()
    }

    @Test func offMeansOffAndShowAgainStartsOver() async {
        let settings = settings()
        settings.tipsEnabled = false
        let store = TipsStore(settings: settings, delay: .zero, dwell: .seconds(60))
        store.islandOpened { TipsStore.Showing(page: .calendar, hasSong: false, lyricsShowing: false) }
        await settle(store)
        #expect(store.current == nil)
        store.islandClosed()
        settings.tipsEnabled = true
        settings.tipsSeen = Tip.allCases.map(\.rawValue)
        store.islandOpened { TipsStore.Showing(page: .music, hasSong: true, lyricsShowing: true) }
        await settle(store)
        #expect(store.current == nil)
        store.islandClosed()
        settings.tipsSeen = []  // Show Tips Again
        store.islandOpened { TipsStore.Showing(page: .music, hasSong: true, lyricsShowing: true) }
        await settle(store)
        #expect(store.current == .menu)
    }
}

import Foundation
import Testing
@testable import BrimCore
@testable import BrimFeatures

/// The full-screen queue's store: asks the playing app its own way, says so when an app can't share, and a click plays
/// the song, then reads the queue again.
@MainActor
struct QueueStoreTests {
    private final class FakeQueue: QueueService, @unchecked Sendable {
        var answer: PlayerQueue = .empty
        var asked: [ScriptablePlayer] = []
        var played: [(String, Int)] = []
        func queue(of player: ScriptablePlayer) async -> PlayerQueue { asked.append(player); return answer }
        func play(_ item: QueueItem, position: Int, in player: ScriptablePlayer) async -> Bool {
            played.append((item.id, position)); return true
        }
    }

    private func store(playing bundle: String) -> (QueueStore, FakeQueue) {
        let island = IslandCoordinator()
        let nowPlaying = NowPlayingStore(service: FakeNowPlayingService(), island: island)
        nowPlaying.handle(.item(NowPlaying(title: "Lantern", artist: "Milo Hart", bundleIdentifier: bundle, isPlaying: true)))
        let fake = FakeQueue()
        return (QueueStore(service: fake, nowPlaying: nowPlaying), fake)
    }

    @Test func spotifyAndMusicAreAskedOthersCantShare() async {
        let (spotify, fake) = store(playing: "com.spotify.client")
        fake.answer = .items(source: "Road Trip", [QueueItem(id: "a", title: "Next", artist: nil)])
        await spotify.refresh()
        #expect(fake.asked == [.spotify] && spotify.queue == fake.answer)
        let (browser, other) = store(playing: "com.google.Chrome")
        await browser.refresh()
        #expect(other.asked.isEmpty)
        if case .unavailable = browser.queue {} else { Issue.record("a browser can't share its queue") }
    }

    @Test func aClickPlaysThenReadsTheQueueAgain() async {
        let (music, fake) = store(playing: "com.apple.Music")
        let song = QueueItem(id: "b#3", title: "Next", artist: nil, musicIndex: 3)
        await music.play(song, position: 1)
        #expect(fake.played.map(\.0) == ["b#3"] && fake.played.map(\.1) == [1])
        #expect(fake.asked == [.music] && music.starting == nil)
    }
}

/// The playing song never shows at the top of Up Next (the app can lag a moment behind a song change).
@MainActor
struct QueueWithoutPlayingTests {
    @Test func thePlayingSongIsDroppedFromTheTop() {
        let playing = NowPlaying(title: "getting over u", artist: "Alyssa Grace", bundleIdentifier: "com.apple.Music", isPlaying: true)
        let list = PlayerQueue.items(source: "Album", [QueueItem(id: "1", title: "getting over u", artist: "Alyssa Grace"),
                                                       QueueItem(id: "2", title: "Set Me Free", artist: "Cameron Whitcomb")])
        #expect(QueueStore.withoutPlaying(list, playing: playing) == .items(source: "Album", [QueueItem(id: "2", title: "Set Me Free", artist: "Cameron Whitcomb")]))
        // A different song first: kept as it is.
        let other = NowPlaying(title: "Gorgeous", artist: "Jessie Murph", bundleIdentifier: "com.apple.Music", isPlaying: true)
        #expect(QueueStore.withoutPlaying(list, playing: other) == list)
    }
}

/// ⌘← in the full-screen player: past 3 s, back to the start; near the start, the song before.
@MainActor
struct RestartOrPreviousTests {
    @Test func pastThreeSecondsRestartsElsePrevious() async {
        let service = FakeNowPlayingService()
        let store = NowPlayingStore(service: service, island: IslandCoordinator())
        func song(at elapsed: TimeInterval) {
            store.handle(.item(NowPlaying(title: "Lantern", artist: "Milo Hart", bundleIdentifier: "com.apple.Music",
                                          isPlaying: false, duration: 200, elapsed: elapsed, timestamp: .now)))
        }
        song(at: 40)
        store.restartOrPrevious()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(service.seeks == [0] && !service.performed.contains(.previousTrack))
        song(at: 1)
        store.restartOrPrevious()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(service.performed.contains(.previousTrack))
    }
}

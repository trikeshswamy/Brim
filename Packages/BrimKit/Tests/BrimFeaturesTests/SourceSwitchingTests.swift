import Foundation
import Testing
@testable import BrimCore
@testable import BrimFeatures

/// Spotify's Web API standing in for covers (0.17.3).
actor FakeCovers: SpotifyCoverService {
    private(set) var asked: [String] = []
    private let answer: Data?
    init(_ answer: Data?) { self.answer = answer }
    func cover(forTrack uri: String) async -> Data? {
        asked.append(uri)
        try? await Task.sleep(for: .milliseconds(30))
        return answer
    }
}

/// Your research item 2: a paused browser video mustn't hide Spotify playing (2026-09-30).
struct SourceSwitchingTests {
    private let cover = Data([1, 2, 3])

    private func make() -> (NowPlayingStore, FakeNowPlayingService, FakePlayerControls) {
        let service = FakeNowPlayingService()
        let controls = FakePlayerControls(nil)
        let store = NowPlayingStore(service: service, island: IslandCoordinator(), controls: controls,
                                    switchDelay: .milliseconds(40))
        return (store, service, controls)
    }
    private func video(playing: Bool) -> NowPlaying {
        NowPlaying(title: "A site is playing media", bundleIdentifier: "company.thebrowser.dia", isPlaying: playing,
                   duration: 900, elapsed: 60, timestamp: .now)
    }
    private func spotifyItem() -> NowPlaying {
        NowPlaying(title: "Easy", artist: "Sam Rowe", album: "Easy", bundleIdentifier: "com.spotify.client",
                   isPlaying: true, duration: 214, elapsed: 20, timestamp: .now, artwork: cover)
    }
    private func spotify(_ state: PlayerAnnouncement.State, title: String = "Easy") -> PlayerAnnouncement {
        PlayerAnnouncement(player: .spotify, state: state, title: title, artist: "Sam Rowe", album: "Easy",
                           duration: 214, position: 30, trackID: "spotify:track:\(title.padding(toLength: 22, withPad: "x", startingAt: 0))",
                           date: .now)
    }
    private func wait(_ ms: Int = 120) async { try? await Task.sleep(for: .milliseconds(ms)) }
    /// Tests run in parallel and share the main thread, so wait for the switch (up to 2 s), not a fixed time.
    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func pausingTheVideoShowsSpotifyAfterAMoment() async {
        let (store, _, _) = make()
        store.handle(.item(spotifyItem()))          // Spotify first: its cover is seen here
        store.handle(.item(video(playing: true)))   // then a video takes Now Playing…
        await waitFor { store.item?.title == "A site is playing media" }  // …and keeps playing, so it shows
        store.handle(spotify(.playing))
        store.handle(.item(video(playing: false)))  // pause the video; Spotify keeps playing
        #expect(store.source == .system)            // not yet: a video pausing for a moment mustn't flicker
        await waitFor { store.source == .player(.spotify) }
        #expect(store.source == .player(.spotify))
        #expect(store.item?.title == "Easy")
        #expect(store.item?.artwork == cover)       // the cover Brim saw earlier
    }

    /// A command Spotify doesn't take fades ⏮ ⏯ ⏭ (your report, 2026-10-02); a read that fails doesn't.
    @Test func aCommandSpotifyDoesntTakeFadesTheButtons() async {
        let service = FakeNowPlayingService()
        let controls = FakePlayerControls(nil, answers: false)
        let store = NowPlayingStore(service: service, island: IslandCoordinator(), controls: controls,
                                    switchDelay: .milliseconds(10))
        store.handle(.item(video(playing: false)))
        store.handle(spotify(.playing))
        await waitFor { store.source == .player(.spotify) }
        #expect(!store.directControlFailed)
        store.nextTrack()
        await waitFor { store.directControlFailed }
        #expect(store.directControlFailed)
        #expect(service.performed.isEmpty)  // never sent to the paused video instead
        store.handle(.item(video(playing: true)))  // back to the video: a fresh start
        await waitFor { store.source == .system }
        #expect(!store.directControlFailed)
    }

    @Test func buttonsGoToSpotifyWhileItsShown() async {
        let (store, service, controls) = make()
        store.handle(.item(video(playing: false)))
        store.handle(spotify(.playing))
        await waitFor { store.source == .player(.spotify) }
        store.togglePlayPause()
        store.nextTrack()
        store.seek(to: 90)
        for _ in 0..<200 where await controls.commands.count < 3 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(await controls.commands == ["togglePlayPause → spotify", "nextTrack → spotify", "seek 90 → spotify"])
        #expect(service.performed.isEmpty)          // nothing went to the paused video
    }

    @Test func resumingTheVideoSwitchesBackAtOnce() async {
        let (store, _, _) = make()
        store.handle(.item(video(playing: false)))
        store.handle(spotify(.playing))
        await waitFor { store.source == .player(.spotify) }
        #expect(store.source == .player(.spotify))
        store.handle(spotify(.paused))              // you pause Spotify…
        store.handle(.item(video(playing: true)))   // …and play the video
        #expect(store.source == .system)
        #expect(store.item?.title == "A site is playing media")
    }

    /// Recorded at 15:40 on 2026-10-02: while Spotify played, a Dia tab played for 0.7 s on its own; macOS's Now
    /// Playing went blank, then to Dia, then stayed on the paused tab. Brim showed "A site is playing media" for 1.7 s.
    @Test func aBackgroundTabBlinkingNeverReplacesSpotify() async {
        let (store, _, _) = make()
        store.handle(.item(spotifyItem()))          // Spotify through Now Playing, with its cover
        store.handle(spotify(.playing))
        store.handle(.item(nil))                    // Now Playing blank for 0.5 s
        store.handle(.item(video(playing: true)))   // the tab plays…
        #expect(store.item?.title == "Easy")
        store.handle(.item(video(playing: false)))  // …for 0.7 s, then Now Playing stays on the paused tab
        #expect(store.item?.title == "Easy")
        #expect(store.source == .player(.spotify))  // at once: Spotify was on screen already
        await wait()
        #expect(store.item?.title == "Easy")
        #expect(store.item?.artwork == cover)       // the cover never turned
    }

    @Test func aVideoYouStartOverSpotifyShowsAMomentLater() async {
        let (store, _, _) = make()
        store.handle(.item(spotifyItem()))
        store.handle(spotify(.playing))
        store.handle(.item(video(playing: true)))   // you start a video while Spotify plays
        #expect(store.item?.title == "Easy")        // not yet: it might be a tab blinking
        await waitFor { store.item?.title == "A site is playing media" }
        #expect(store.item?.title == "A site is playing media")
    }

    @Test func aVideoPausingBrieflyNeverFlickers() async {
        let (store, _, _) = make()
        store.handle(spotify(.playing))
        store.handle(.item(video(playing: false)))  // buffering…
        store.handle(.item(video(playing: true)))   // …back within the wait
        await wait()
        #expect(store.source == .system)
        #expect(store.item?.title == "A site is playing media")
    }

    /// Recorded 2026-10-02: macOS's Now Playing stayed on a paused tab for 9 minutes while Spotify played 9 songs, and
    /// they showed no covers. Brim now asks Spotify's Web API, once per song.
    @Test func spotifyOnItsOwnGetsEachSongsCover() async {
        let fetched = Data([9, 9, 9])
        let covers = FakeCovers(fetched)
        let store = NowPlayingStore(service: FakeNowPlayingService(), island: IslandCoordinator(), coverSource: covers,
                                    switchDelay: .milliseconds(10))
        store.handle(.item(video(playing: false)))           // the paused tab holds Now Playing
        store.handle(spotify(.playing, title: "Next song"))  // Spotify's next song: no cover seen anywhere
        await waitFor { store.item?.artwork == fetched }
        #expect(store.source == .player(.spotify))
        #expect(store.item?.artwork == fetched)
        store.handle(spotify(.playing, title: "Next song")) // announced again (a seek, Shuffle…)
        store.handle(.item(video(playing: false)))           // the tab's Now Playing changes
        await wait()
        #expect(await covers.asked == ["spotify:track:Next songxxxxxxxxxxxxx"])   // asked once
    }

    @Test func aCoverThatDoesntComeIsntAskedForAgain() async {
        let covers = FakeCovers(nil)                         // signed out or offline
        let store = NowPlayingStore(service: FakeNowPlayingService(), island: IslandCoordinator(), coverSource: covers,
                                    switchDelay: .milliseconds(10))
        store.handle(.item(video(playing: false)))
        store.handle(spotify(.playing, title: "Next song"))
        await waitFor { store.source == .player(.spotify) }
        await wait()
        store.handle(spotify(.playing, title: "Next song"))
        await wait()
        #expect(await covers.asked.count == 1)
        #expect(store.item?.artwork == nil)
    }

    /// 0.18.2: Spotify playing behind a paused tab as Brim starts. Its Web API read shows it; its own announcement wins.
    @Test func aStartReadShowsSpotifyBehindAPausedTab() async {
        let (store, _, _) = make()
        store.handle(.item(video(playing: false)))           // the paused tab holds Now Playing
        store.seed(spotify(.playing))                        // Spotify's Web API, as Brim starts
        await waitFor { store.source == .player(.spotify) }
        #expect(store.item?.title == "Easy")
        store.handle(spotify(.paused, title: "Next song"))   // Spotify's own announcement
        store.seed(spotify(.playing, title: "Old read"))      // a late read changes nothing
        #expect(store.item?.title == "Next song")
    }

    @Test func quittingSpotifyGoesBackToNowPlaying() async {
        let (store, _, _) = make()
        store.handle(.item(video(playing: false)))
        store.handle(spotify(.playing))
        await waitFor { store.source == .player(.spotify) }
        #expect(store.source == .player(.spotify))
        store.handle(PlayerAnnouncement(player: .spotify, state: .stopped, date: .now))
        #expect(store.source == .system)
    }
}

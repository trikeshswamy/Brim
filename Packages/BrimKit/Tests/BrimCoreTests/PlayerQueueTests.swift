import Foundation
import Testing
@testable import BrimCore

/// The queue, per app (2026-10-29): Music's rest of the album or playlist, Spotify's Up Next, and how a song plays now.
struct PlayerQueueTests {
    @Test func musicListsTheSongsAfterThePlayingOne() {
        let items = QueueRules.upNext(ids: ["a", "b", "c", "d"], titles: ["A", "B", "C", "D"], artists: ["Nora", "", "Milo", "Ivy"],
                                      albums: ["X", "X", "Y", "X"], current: "b", currentAlbum: "X")
        #expect(items.map(\.title) == ["C", "D"])
        #expect(items.map(\.musicIndex) == [3, 4])  // its place in the playlist, to play it
        #expect(items.map(\.sameAlbumAsPlaying) == [false, true])
        #expect(QueueRules.upNext(ids: ["a"], titles: ["A"], artists: [""], albums: [""], current: "z", currentAlbum: nil).isEmpty)
        #expect(QueueRules.upNext(ids: ["a", "b"], titles: ["A", "B"], artists: ["", ""], albums: ["", ""], current: "b",
                                  currentAlbum: nil).isEmpty)  // the last song
    }

    @Test func musicListsAtMost25() {
        let ids = (0..<100).map { "\($0)" }
        let items = QueueRules.upNext(ids: ids, titles: ids, artists: ids, albums: ids, current: "0", currentAlbum: nil)
        #expect(items.count == QueueRules.limit && items.first?.musicIndex == 2)
    }

    @Test func spotifysQueueWithSmallSharpCovers() {
        let reply = #"""
        {"currently_playing": {"name": "Now"}, "queue": [
          {"uri": "spotify:track:1", "name": "Lantern", "artists": [{"name": "Milo Hart"}, {"name": "Nora Vale"}],
           "album": {"images": [{"url": "https://i.scdn.co/image/big", "width": 640},
                                {"url": "https://i.scdn.co/image/mid", "width": 300},
                                {"url": "https://i.scdn.co/image/small", "width": 64}]}},
          {"uri": "spotify:episode:2", "name": "Episode", "show": {"name": "A Show"},
           "images": [{"url": "https://evil.example/x", "width": 300}]}
        ]}
        """#
        let items = SpotifyWeb.queue(from: Data(reply.utf8))
        #expect(items.map(\.title) == ["Lantern", "Episode"])
        #expect(items[0].artist == "Milo Hart, Nora Vale" && items[1].artist == "A Show")
        #expect(items[0].artworkURL?.absoluteString == "https://i.scdn.co/image/mid")
        #expect(items[1].artworkURL == nil)  // only Spotify's image server
        #expect(items[0].spotifyURI == "spotify:track:1")
    }

    /// Your report, 2026-11-17: a song Spotify added after the album played only after Brim pressed Next through
    /// every song before it. Now it plays at once, with the rest of Up Next after it.
    @Test func spotifyPlaysASongOutsideTheAlbumAtOnce() throws {
        let queue = Data(#"{"queue": [{"name": "A", "uri": "spotify:track:1", "artists": []}, {"name": "B", "uri": "spotify:track:2", "artists": []}, {"name": "C", "uri": "spotify:track:3", "artists": []}]}"#.utf8)
        let items = SpotifyWeb.queue(from: queue)
        let body = try #require(SpotifyWeb.listBody(queue: items, from: "spotify:track:2"))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["uris"] as? [String] == ["spotify:track:2", "spotify:track:3"])
        #expect(SpotifyWeb.listBody(queue: items, from: "spotify:track:9") == nil)
    }

    @Test func spotifyPlaysASongInsideItsPlaylist() throws {
        let player = Data(#"{"context": {"uri": "spotify:playlist:abc"}}"#.utf8)
        #expect(SpotifyWeb.contextURI(fromPlayer: player) == "spotify:playlist:abc")
        #expect(SpotifyWeb.contextNamePath(for: "spotify:playlist:abc") == "/playlists/abc?fields=name")
        #expect(SpotifyWeb.contextNamePath(for: "spotify:album:xyz") == "/albums/xyz")
        #expect(SpotifyWeb.contextNamePath(for: "spotify:artist:1") == nil)
        let body = try #require(SpotifyWeb.playBody(context: "spotify:playlist:abc", track: "spotify:track:1"))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["context_uri"] as? String == "spotify:playlist:abc")
        #expect((json["offset"] as? [String: String])?["uri"] == "spotify:track:1")
    }
}

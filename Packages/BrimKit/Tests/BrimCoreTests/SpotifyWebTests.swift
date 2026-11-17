import Foundation
import Testing
@testable import BrimCore

/// Spotify's Web API for Shuffle & Repeat from anywhere (your decision, 2026-10-02): the pure parts.
struct SpotifyWebTests {
    /// RFC 7636, appendix B: the standard test vector.
    @Test func pkceChallengeMatchesTheStandard() {
        #expect(SpotifyWeb.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = SpotifyWeb.makeVerifier()
        #expect(verifier.count == 64)
        #expect(verifier.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) })
    }

    /// Your screenshot (2026-10-02): the dashboard refuses a loopback address without a port; this one, exactly.
    @Test func theRegisteredRedirectHasItsPort() {
        #expect(SpotifyWeb.registeredRedirect == "http://127.0.0.1:42813/callback")
    }

    @Test func authorizeAsksForPlaybackAndLikedSongsWithPKCE() {
        let url = SpotifyWeb.authorizeURL(clientID: "abc", redirect: SpotifyWeb.redirect(port: 51234), challenge: "xyz", state: "s1")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        #expect(url.host == "accounts.spotify.com")
        #expect(value("redirect_uri") == "http://127.0.0.1:51234/callback")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("scope") == "user-read-playback-state user-modify-playback-state user-library-read user-library-modify")
        #expect(value("response_type") == "code")
    }

    @Test func theBrowsersReplyIsReadOnlyWithOurState() {
        #expect(SpotifyWeb.callback(fromRequestLine: "GET /callback?code=C0DE&state=s1 HTTP/1.1", expectedState: "s1") == .code("C0DE"))
        #expect(SpotifyWeb.callback(fromRequestLine: "GET /callback?error=access_denied&state=s1 HTTP/1.1", expectedState: "s1")
            == .refused("access_denied"))
        #expect(SpotifyWeb.callback(fromRequestLine: "GET /callback?code=C0DE&state=other HTTP/1.1", expectedState: "s1") == .notOurs)
        #expect(SpotifyWeb.callback(fromRequestLine: "GET /favicon.ico HTTP/1.1", expectedState: "s1") == .notOurs)
    }

    @Test func formBodyIsEncoded() {
        let body = String(decoding: SpotifyWeb.formBody([("redirect_uri", "http://127.0.0.1:5/callback"), ("a", "b c")]), as: UTF8.self)
        #expect(body == "redirect_uri=http%3A%2F%2F127.0.0.1%3A5%2Fcallback&a=b%20c")
    }

    @Test func tokensAreRead() {
        let data = Data(#"{"access_token":"A","token_type":"Bearer","expires_in":3600,"refresh_token":"R","scope":"x"}"#.utf8)
        #expect(SpotifyWeb.tokens(from: data) == SpotifyWeb.Tokens(access: "A", expiresIn: 3600, refresh: "R", scope: "x"))
        #expect(SpotifyWeb.tokens(from: Data(#"{"access_token":"B","expires_in":3600}"#.utf8))?.refresh == nil)  // keep the old one
    }

    /// All three Repeat states, which Spotify's menu couldn't tell apart (your report: no "1").
    @Test func playerStateGivesAllThreeRepeatStates() {
        func modes(_ repeatState: String, disallows: String = "{}") -> PlayerModes? {
            SpotifyWeb.modes(fromPlayer: Data(#"{"shuffle_state":true,"repeat_state":"\#(repeatState)","actions":{"disallows":\#(disallows)}}"#.utf8))
        }
        #expect(modes("track")?.repeatMode == .one)
        #expect(modes("context")?.repeatMode == .all)
        #expect(modes("off")?.repeatMode == .off)
        #expect(modes("off")?.shuffle == true && modes("off")?.repeatHasOne == true)
        #expect(modes("off")?.canChange == true)
        #expect(modes("off", disallows: #"{"toggling_shuffle":true}"#)?.canChange == false)  // radio, DJ…
        #expect(SpotifyWeb.modes(fromPlayer: Data("{}".utf8)) == nil)
    }

    /// 0.17.3: a cover for Spotify's song while macOS's Now Playing is on another app.
    @Test func coverLookupsTakeOnlyTrackIDsAndSpotifysImageServer() throws {
        #expect(SpotifyWeb.trackID(fromURI: "spotify:track:44AyOl4qVkzS48vBsbNXaC") == "44AyOl4qVkzS48vBsbNXaC")
        #expect(SpotifyWeb.trackID(fromURI: "spotify:local:Artist:Album:Song:214") == nil)   // a local file: no cover online
        #expect(SpotifyWeb.trackID(fromURI: "spotify:episode:4rOoJ6Egrf8K2IrywzwOMk") == nil)
        #expect(SpotifyWeb.trackID(fromURI: "spotify:track:../../me/player") == nil)        // nothing odd in a request
        // `GET /v1/tracks/{id}`, trimmed: Spotify lists 640, 300 and 64 px.
        let track = Data(#"""
        {"album":{"images":[{"url":"https://i.scdn.co/image/ab67616d0000b273aaa","width":640,"height":640},
                            {"url":"https://i.scdn.co/image/ab67616d00001e02aaa","width":300,"height":300},
                            {"url":"https://i.scdn.co/image/ab67616d00004851aaa","width":64,"height":64}]}}
        """#.utf8)
        #expect(SpotifyWeb.coverURL(fromTrack: track)?.absoluteString == "https://i.scdn.co/image/ab67616d0000b273aaa")
        let elsewhere = Data(#"{"album":{"images":[{"url":"https://example.com/a.jpg","width":640}]}}"#.utf8)
        #expect(SpotifyWeb.coverURL(fromTrack: elsewhere) == nil)                           // only i.scdn.co
        let plain = Data(#"{"album":{"images":[{"url":"http://i.scdn.co/image/a","width":640}]}}"#.utf8)
        #expect(SpotifyWeb.coverURL(fromTrack: plain) == nil)                               // only https
        #expect(SpotifyWeb.coverURL(fromTrack: Data(#"{"album":{"images":[]}}"#.utf8)) == nil)
    }

    /// 0.18.2: what Spotify is playing as Brim starts, from `GET /v1/me/player`.
    @Test func theStartReadSeesOnlyThisMacsTrack() throws {
        func player(device: String = "Computer", type: String = "track", playing: Bool = true) -> Data {
            Data(#"""
            {"device":{"type":"\#(device)","is_active":true},"is_playing":\#(playing),"progress_ms":61500,
             "item":{"type":"\#(type)","name":"Let Me Down Slowly","uri":"spotify:track:2qxmye6gAegTMjLKEBoR3d",
                     "duration_ms":169353,"artists":[{"name":"Alec Benjamin"},{"name":"Alessia Cara"}],
                     "album":{"name":"Narrated For You"}}}
            """#.utf8)
        }
        let now = Date()
        let song = try #require(SpotifyWeb.announcement(fromPlayer: player(), at: now))
        #expect(song.state == .playing && song.title == "Let Me Down Slowly" && song.album == "Narrated For You")
        #expect(song.artist == "Alec Benjamin")                              // the first artist, as Spotify announces it
        #expect(song.trackID == "spotify:track:2qxmye6gAegTMjLKEBoR3d")      // for its cover
        #expect(abs((song.duration ?? 0) - 169.353) < 0.001 && song.position == 61.5 && song.date == now)
        #expect(SpotifyWeb.announcement(fromPlayer: player(playing: false), at: now)?.state == .paused)
        #expect(SpotifyWeb.announcement(fromPlayer: player(device: "Smartphone"), at: now) == nil)  // your phone
        #expect(SpotifyWeb.announcement(fromPlayer: player(type: "episode"), at: now) == nil)
        #expect(SpotifyWeb.announcement(fromPlayer: Data("{}".utf8), at: now) == nil)              // nothing playing
    }

    /// 0.18.3: ★ through your Liked Songs (`/v1/me/library`).
    @Test func likedSongsNeedBothPermissionsAndTakeOnlyTracks() {
        // A sign-in from before ★ keeps its two permissions; refreshing doesn't add any.
        #expect(!SpotifyWeb.allowsLikedSongs(scope: "user-read-playback-state user-modify-playback-state"))
        #expect(!SpotifyWeb.allowsLikedSongs(scope: "user-modify-playback-state user-library-read"))
        #expect(SpotifyWeb.allowsLikedSongs(scope: "user-library-modify user-read-playback-state user-library-read"))
        // One song per request, spelled as Spotify's reference spells it; nothing but a track ID gets in.
        #expect(SpotifyWeb.libraryQuery(forTrack: "spotify:track:44AyOl4qVkzS48vBsbNXaC")
            == "uris=spotify%3Atrack%3A44AyOl4qVkzS48vBsbNXaC")
        #expect(SpotifyWeb.libraryQuery(forTrack: "spotify:local:Artist:Album:Song:214") == nil)
        #expect(SpotifyWeb.libraryQuery(forTrack: "spotify:episode:4rOoJ6Egrf8K2IrywzwOMk") == nil)
        #expect(SpotifyWeb.libraryQuery(forTrack: "spotify:track:44AyOl4qVkzS48vBsbNX&a") == nil)
        // `GET /v1/me/library/contains` answers one true or false per song.
        #expect(SpotifyWeb.liked(fromContains: Data("[true]".utf8)) == true)
        #expect(SpotifyWeb.liked(fromContains: Data("[false]".utf8)) == false)
        #expect(SpotifyWeb.liked(fromContains: Data("[]".utf8)) == nil)
        #expect(SpotifyWeb.liked(fromContains: Data(#"{"error":{"status":403}}"#.utf8)) == nil)
        // A refusal for a missing permission, as Spotify words it.
        #expect(SpotifyWeb.isMissingPermission(Data(#"{"error":{"status":403,"message":"Insufficient client scope"}}"#.utf8)))
        #expect(!SpotifyWeb.isMissingPermission(Data(#"{"error":{"status":403,"message":"Forbidden"}}"#.utf8)))
    }

    /// Before Spotify's app has announced a song (Brim just started), ★ asks the Web API which one is playing.
    @Test func thePlayingSongIsReadOnlyForTracks() {
        func player(_ uri: String) -> Data { Data(#"{"item":{"type":"track","uri":"\#(uri)"}}"#.utf8) }
        #expect(SpotifyWeb.playingTrack(fromPlayer: player("spotify:track:2qxmye6gAegTMjLKEBoR3d")) == "spotify:track:2qxmye6gAegTMjLKEBoR3d")
        #expect(SpotifyWeb.playingTrack(fromPlayer: player("spotify:episode:4rOoJ6Egrf8K2IrywzwOMk")) == nil)
        #expect(SpotifyWeb.playingTrack(fromPlayer: Data("{}".utf8)) == nil)
    }

    @Test func repeatStatesAsSpotifyNamesThem() {
        #expect(SpotifyWeb.repeatState(.off) == "off")
        #expect(SpotifyWeb.repeatState(.all) == "context")
        #expect(SpotifyWeb.repeatState(.one) == "track")
        #expect(SpotifyWeb.reason(from: Data(#"{"error":{"status":403,"message":"Premium required","reason":"PREMIUM_REQUIRED"}}"#.utf8))
            == "PREMIUM_REQUIRED")
    }
}

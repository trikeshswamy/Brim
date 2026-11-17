import CryptoKit
import Foundation

/// Spotify's Web API, for Shuffle & Repeat from anywhere (your decision, 2026-10-02) and ★ (0.18.3). Spotify 1.3.3
/// left no route on the Mac itself: its scripting is silent, its menu works only while it's in front and shows one
/// checkmark for All and One, its window hides its buttons, and it ignores macOS's repeat/shuffle commands (all
/// measured). The Web API reads and sets all three Repeat states for the device you're playing on, wherever you are on
/// the Mac, and adds songs to your Liked Songs.
///
/// Requirements (checked 2026-10-02): Spotify Premium for the app's owner (you) and for these endpoints; a free app at
/// developer.spotify.com; sign-in through the browser (PKCE: no secret in Brim); the sign-in lasts 6 months.
/// Pure parts here, so they're tested; the network and the keychain live in `BrimSystem`.
public enum SpotifyWeb {
    /// Playback (Shuffle & Repeat), and since 0.18.3 your Liked Songs (★): `likedSongsScopes`.
    public static let scopes = (["user-read-playback-state", "user-modify-playback-state"] + likedSongsScopes)
        .joined(separator: " ")
    /// What you register in your Spotify app, exactly. Spotify's docs say a loopback address may leave the port out,
    /// but its dashboard refuses that ("This redirect URI is not secure", your screenshot 2026-10-02) and accepts an
    /// explicit port, so Brim listens on this one, only while you sign in. (`localhost` isn't allowed any more.)
    /// 42813: not a port any common service uses, and below macOS's range for temporary ports (49152+).
    public static let redirectPort: UInt16 = 42813
    public static let registeredRedirect = redirect(port: redirectPort)
    public static let redirectPath = "/callback"
    /// UserDefaults: the Client ID you pasted in Settings (not a secret: PKCE apps have none).
    public static let clientIDKey = "spotify.clientID"

    public static func redirect(port: UInt16) -> String { "http://127.0.0.1:\(port)\(redirectPath)" }

    // MARK: Sign-in (PKCE, RFC 7636)

    /// 64 characters from the unreserved set.
    public static func makeVerifier() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<64).map { _ in alphabet.randomElement()! })
    }

    /// base64url(SHA-256(verifier)), no padding.
    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func authorizeURL(clientID: String, redirect: String, challenge: String, state: String) -> URL {
        var parts = URLComponents(string: "https://accounts.spotify.com/authorize")!
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
        ]
        return parts.url!
    }

    /// The browser's redirect: `GET /callback?code=…&state=…` (or `?error=…`).
    public enum Callback: Equatable, Sendable {
        case code(String)
        case refused(String)
        case notOurs
    }

    public static func callback(fromRequestLine line: String, expectedState: String) -> Callback {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let url = URLComponents(string: "http://127.0.0.1" + parts[1]),
              url.path == redirectPath else { return .notOurs }
        let items = Dictionary(url.queryItems?.compactMap { item in item.value.map { (item.name, $0) } } ?? [],
                               uniquingKeysWith: { first, _ in first })
        guard items["state"] == expectedState else { return .notOurs }
        if let error = items["error"] { return .refused(error) }
        return items["code"].map(Callback.code) ?? .notOurs
    }

    /// The form body for `POST https://accounts.spotify.com/api/token`.
    public static func formBody(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
    }

    public struct Tokens: Equatable, Sendable {
        public var access: String
        public var expiresIn: TimeInterval
        /// Spotify may send a new one on refresh; keep the old one if it doesn't.
        public var refresh: String?
        /// The permissions this sign-in has, space-separated, as Spotify grants them (on refresh too). A sign-in from
        /// before 0.18.3 keeps the two it had: ★ needs `likedSongsScopes` (`allowsLikedSongs`).
        public var scope: String?
    }

    public static func tokens(from data: Data) -> Tokens? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else { return nil }
        return Tokens(access: access, expiresIn: (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600,
                      refresh: json["refresh_token"] as? String, scope: json["scope"] as? String)
    }

    // MARK: Player

    /// `GET /v1/me/player` → shuffle and all three Repeat states. Spotify says which changes the queue allows
    /// (`actions.disallows`, e.g. in radio or DJ).
    public static func modes(fromPlayer data: Data) -> PlayerModes? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let shuffle = json["shuffle_state"] as? Bool, let repeatState = json["repeat_state"] as? String else { return nil }
        let repeatMode: RepeatMode = switch repeatState {
        case "track": .one
        case "context": .all
        default: .off
        }
        let disallows = (json["actions"] as? [String: Any])?["disallows"] as? [String: Any] ?? [:]
        let locked = disallows["toggling_shuffle"] as? Bool == true || disallows["toggling_repeat_context"] as? Bool == true
        return PlayerModes(shuffle: shuffle, repeatMode: repeatMode, canChange: !locked, repeatHasOne: true)
    }

    /// `PUT /v1/me/player/repeat?state=…`
    public static func repeatState(_ mode: RepeatMode) -> String {
        switch mode {
        case .off: "off"
        case .all: "context"
        case .one: "track"
        }
    }

    /// `GET /v1/me/player` → what Spotify is playing, as its own announcement would say it (0.18.2): for the moment Brim
    /// starts, before Spotify's next announcement. Nil for another device (your phone through Spotify Connect), an
    /// episode or an ad, or nothing playing. The artist is the first one, as Spotify's announcements give it.
    public static func announcement(fromPlayer data: Data, at date: Date) -> PlayerAnnouncement? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = json["device"] as? [String: Any], (device["type"] as? String)?.lowercased() == "computer",
              let item = json["item"] as? [String: Any], item["type"] as? String == "track",
              let title = item["name"] as? String, !title.isEmpty else { return nil }
        let artist = (item["artists"] as? [[String: Any]])?.first?["name"] as? String
        let album = (item["album"] as? [String: Any])?["name"] as? String
        return PlayerAnnouncement(player: .spotify, state: json["is_playing"] as? Bool == true ? .playing : .paused,
                                  title: title, artist: artist, album: album,
                                  duration: (item["duration_ms"] as? NSNumber).map { $0.doubleValue / 1000 },
                                  position: (json["progress_ms"] as? NSNumber).map { $0.doubleValue / 1000 },
                                  trackID: item["uri"] as? String, date: date)
    }

    // MARK: Covers (0.17.3)

    /// The only server Brim downloads covers from: Spotify's image server (your OK, 2026-10-02).
    public static let coverHost = "i.scdn.co"

    /// "spotify:track:44AyOl4qVkzS48vBsbNXaC" → "44AyOl4qVkzS48vBsbNXaC". Nil for local files, episodes, or anything
    /// that isn't a 22-character track ID (so nothing odd ends up in a request).
    public static func trackID(fromURI uri: String) -> String? {
        let prefix = "spotify:track:"
        guard uri.hasPrefix(prefix) else { return nil }
        let id = String(uri.dropFirst(prefix.count))
        guard id.count == 22, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return id
    }

    /// `GET /v1/tracks/{id}` → the cover to download: the largest up to 640 px (Spotify offers 640, 300 and 64), and
    /// only an https address on `coverHost`.
    public static func coverURL(fromTrack data: Data) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let album = json["album"] as? [String: Any], let images = album["images"] as? [[String: Any]] else { return nil }
        let sized = images.compactMap { image -> (url: URL, width: Int)? in
            guard let text = image["url"] as? String, let url = URL(string: text), url.scheme == "https",
                  url.host == coverHost else { return nil }
            return (url, image["width"] as? Int ?? 0)
        }
        return (sized.filter { $0.width <= 640 }.max { $0.width < $1.width } ?? sized.first)?.url
    }

    // MARK: ★ Liked Songs (0.18.3)

    /// What ★ needs (your OK, 2026-10-05): seeing whether a song is in your Liked Songs, and adding or removing it.
    /// Spotify's app on the Mac offers other apps no way to do either; its Web API does (`/v1/me/library`, the
    /// library endpoints since February 2026).
    public static let likedSongsScopes = ["user-library-read", "user-library-modify"]

    /// Whether a sign-in's permissions (`Tokens.scope`) cover ★.
    public static func allowsLikedSongs(scope: String) -> Bool {
        let granted = Set(scope.split(separator: " ").map(String.init))
        return likedSongsScopes.allSatisfy(granted.contains)
    }

    /// The query for `GET /v1/me/library/contains`, `PUT /v1/me/library` (add) and `DELETE /v1/me/library` (remove):
    /// one song, spelled as Spotify's reference spells it. Nil for anything but a track (local files, episodes, ads),
    /// so nothing odd ends up in a request.
    public static func libraryQuery(forTrack uri: String) -> String? {
        trackID(fromURI: uri).map { "uris=spotify%3Atrack%3A\($0)" }
    }

    /// `GET /v1/me/library/contains` → `[true]` (in your Liked Songs) or `[false]`.
    public static func liked(fromContains data: Data) -> Bool? {
        (try? JSONSerialization.jsonObject(with: data) as? [Bool])?.first
    }

    /// `GET /v1/me/player` → the playing song's "spotify:track:…", for ★ before Spotify's app has announced one (Brim
    /// just started). Nil for episodes, ads, local files, or nothing playing.
    public static func playingTrack(fromPlayer data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = json["item"] as? [String: Any], let uri = item["uri"] as? String,
              trackID(fromURI: uri) != nil else { return nil }
        return uri
    }

    /// A 403 because the sign-in lacks a permission (`{"error": {"message": "Insufficient client scope"}}`): a sign-in
    /// from before ★ whose token didn't list its permissions.
    public static func isMissingPermission(_ data: Data) -> Bool {
        reason(from: data)?.localizedCaseInsensitiveContains("scope") == true
    }

    /// Spotify's reason for a refusal (`{"error": {"reason": "PREMIUM_REQUIRED", …}}`), when it gives one.
    public static func reason(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["reason"] as? String ?? error["message"] as? String
    }
}

/// Your Spotify sign-in, as Settings shows it.
public enum SpotifyAccountState: Equatable, Sendable {
    case signedOut
    case signingIn
    case signedIn
    /// Why it didn't work, in plain words.
    case failed(String)
}

/// Sign in to and out of Spotify's Web API. Live: `SpotifyWebAPI` (BrimSystem); tests: a fake.
public protocol SpotifyAccountService: Sendable {
    func currentState() async -> SpotifyAccountState
    func signIn(clientID: String) async -> SpotifyAccountState
    func signOut() async
}

/// A Spotify track's cover from its Web API, for when macOS's Now Playing is on another app and Spotify's own
/// announcements carry none (0.17.3). Live: `SpotifyWebAPI`; tests: a fake.
public protocol SpotifyCoverService: Sendable {
    /// The cover's image bytes for "spotify:track:…", or nil: signed out, offline, or no image.
    func cover(forTrack uri: String) async -> Data?
}

extension SpotifyWeb {

    // MARK: Queue (2026-10-29)

    /// `GET /me/player/queue` → the songs after the playing one (episodes too), each with a small cover.
    public static func queue(from data: Data) -> [QueueItem] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["queue"] as? [[String: Any]] else { return [] }
        return entries.prefix(QueueRules.limit).enumerated().compactMap { index, entry in
            guard let uri = entry["uri"] as? String, let name = entry["name"] as? String else { return nil }
            let artists = (entry["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
            let show = (entry["show"] as? [String: Any])?["name"] as? String
            let images = ((entry["album"] as? [String: Any])?["images"] ?? entry["images"]) as? [[String: Any]] ?? []
            // The smallest cover that's still sharp at 44 pt on a Retina screen.
            let image = images.filter { ($0["width"] as? Int ?? 0) >= 88 }.last ?? images.last
            let url = (image?["url"] as? String).flatMap(URL.init(string:)).flatMap { $0.host == "i.scdn.co" ? $0 : nil }
            return QueueItem(id: "\(uri)#\(index)", title: name, artist: artists?.joined(separator: ", ") ?? show,
                             artworkURL: url, spotifyURI: uri)
        }
    }

    /// `GET /me/player` → what's being played from ("spotify:playlist:…", "spotify:album:…"), if anything.
    public static func contextURI(fromPlayer data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["context"] as? [String: Any])?["uri"] as? String
    }

    /// The path that names a playlist or album: "spotify:playlist:ID" → "/playlists/ID?fields=name".
    public static func contextNamePath(for uri: String) -> String? {
        let parts = uri.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify" else { return nil }
        switch parts[1] {
        case "playlist": return "/playlists/\(parts[2])?fields=name"
        case "album": return "/albums/\(parts[2])"
        default: return nil
        }
    }

    /// `PUT /me/player/play` body: the song, inside the album or playlist it's from, so what follows plays on.
    public static func playBody(context: String, track: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["context_uri": context, "offset": ["uri": track]])
    }

    /// A song that isn't in the playing playlist or album (one Spotify added after it, or one you queued): it plays
    /// now, with the rest of Up Next after it, in order (at most 50). Nil if it's not in the queue.
    public static func listBody(queue: [QueueItem], from track: String) -> Data? {
        let uris = queue.compactMap(\.spotifyURI)
        guard let start = uris.firstIndex(of: track) else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["uris": Array(uris[start...].prefix(50))])
    }
}

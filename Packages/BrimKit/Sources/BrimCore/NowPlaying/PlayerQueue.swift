import Foundation

/// One song in the queue, as the full-screen player lists it (2026-10-29, your picks: per app; click to play).
public struct QueueItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var artist: String?
    /// Spotify: the cover on i.scdn.co.
    public var artworkURL: URL?
    /// Apple Music: same album as the song playing, so its cover is the one already on screen.
    public var sameAlbumAsPlaying: Bool
    /// What playing it needs: Spotify's track URI, or the song's place in Music's current playlist (1-based).
    public var spotifyURI: String?
    public var musicIndex: Int?
    /// Apple Music's catalog page for a song from an album not in your Library: clicking opens it in Music.
    public var storeURL: URL?

    public init(id: String, title: String, artist: String?, artworkURL: URL? = nil, sameAlbumAsPlaying: Bool = false,
                spotifyURI: String? = nil, musicIndex: Int? = nil, storeURL: URL? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.sameAlbumAsPlaying = sameAlbumAsPlaying
        self.spotifyURI = spotifyURI
        self.musicIndex = musicIndex
        self.storeURL = storeURL
    }
}

/// What the Queue shows. macOS gives apps no way to read another app's queue, so each app is asked its own way.
public enum PlayerQueue: Equatable, Sendable {
    case loading
    /// Spotify's Up Next, or the rest of Music's album or playlist; `source`: its name, when known.
    case items(source: String?, [QueueItem])
    /// Music with Shuffle on: it doesn't share the shuffled order.
    case shuffled(source: String?)
    /// Music streaming something that isn't in your Library: it has no playlist to share.
    case musicLibraryOnly
    /// Spotify, before you connect it in Settings → Media & Lyrics.
    case spotifyNotConnected
    /// Any other app (YouTube Music, a browser…): it doesn't share its queue.
    case unavailable(app: String?)
    /// Nothing after this song.
    case empty
}

public protocol QueueService: Sendable {
    func queue(of player: ScriptablePlayer) async -> PlayerQueue
    /// Plays a queued song now. `position`: its place in the list (0 = next).
    func play(_ item: QueueItem, position: Int, in player: ScriptablePlayer) async -> Bool
    /// A queued song's cover, when the app has it on your Mac (Music: the song's own artwork).
    func cover(of item: QueueItem, in player: ScriptablePlayer) async -> Data?
}

public extension QueueService {
    func cover(of item: QueueItem, in player: ScriptablePlayer) async -> Data? { nil }
}

public enum QueueRules {
    /// Most songs listed: enough to see what's coming without loading a whole library.
    public static let limit = 25

    /// Music: the songs after the playing one in its current playlist (or album), from the playlist's lists of
    /// IDs, names, artists and albums. Empty when the playing song isn't in it.
    public static func upNext(ids: [String], titles: [String], artists: [String], albums: [String],
                              current: String, currentAlbum: String?) -> [QueueItem] {
        guard let index = ids.firstIndex(of: current) else { return [] }
        let count = min(ids.count, titles.count, artists.count, albums.count)
        guard index + 1 < count else { return [] }
        return (index + 1..<min(count, index + 1 + limit)).map { i in
            QueueItem(id: "\(ids[i])#\(i)", title: titles[i], artist: artists[i].isEmpty ? nil : artists[i],
                      sameAlbumAsPlaying: currentAlbum.map { !$0.isEmpty && $0 == albums[i] } ?? false, musicIndex: i + 1)
        }
    }
}

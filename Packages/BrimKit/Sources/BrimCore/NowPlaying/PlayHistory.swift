import Foundation

/// A song you played, for History above Up Next in the full-screen queue (your picks, 2026-10-29: like Apple Music's,
/// one History per app, the last 50 songs each, kept on your Mac).
public struct HistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var artist: String?
    /// What playing it again needs: Spotify's track URI or Music's persistent ID, read while it played.
    public var songID: String?
    /// A small cover (JPEG), so History shows it after the song is gone.
    public var cover: Data?
    public var playedAt: Date

    public init(id: UUID = UUID(), title: String, artist: String?, songID: String? = nil, cover: Data? = nil,
                playedAt: Date = .now) {
        self.id = id
        self.title = title
        self.artist = artist
        self.songID = songID
        self.cover = cover
        self.playedAt = playedAt
    }
}

public enum PlayHistoryRules {
    /// Songs kept per app.
    public static let limit = 50
    /// A song counts as played after this long: a title flickering past doesn't.
    public static let minimumPlay: TimeInterval = 5

    /// `list` is oldest first. The same song twice in a row is kept once (a pause or a dropout isn't a replay).
    public static func adding(_ entry: HistoryEntry, to list: [HistoryEntry]) -> [HistoryEntry] {
        if let last = list.last, last.title == entry.title, last.artist == entry.artist { return list }
        return Array((list + [entry]).suffix(limit))
    }

    /// Spotify track URIs and Music persistent IDs only, so nothing else ever reaches a script.
    public static func isValidSongID(_ id: String, for player: ScriptablePlayer) -> Bool {
        switch player {
        case .spotify:
            let track = id.dropFirst("spotify:track:".count)
            return id.hasPrefix("spotify:track:") && track.count == 22 && track.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        case .music:
            return (8...32).contains(id.count) && id.allSatisfy(\.isHexDigit)
        }
    }
}

/// Reads and plays songs in the app they came from.
public protocol HistoryService: Sendable {
    /// The playing song's ID in that app (see `HistoryEntry.songID`).
    func currentSongID(in player: ScriptablePlayer) async -> String?
    func play(_ entry: HistoryEntry, in player: ScriptablePlayer) async -> Bool
}

/// Where History is kept: one list per app, by bundle ID.
public protocol HistoryFile: Sendable {
    func load() -> [String: [HistoryEntry]]
    func save(_ history: [String: [HistoryEntry]])
}

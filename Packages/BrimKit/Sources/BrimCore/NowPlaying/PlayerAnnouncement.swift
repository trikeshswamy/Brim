import Foundation

/// What Spotify or Music announced about itself. Both post a system-wide notification on every play, pause,
/// and track change, with no permission needed (checked 2026-09-30, Spotify 1.3.0 on macOS 27:
/// "Player State", "Name", "Artist", "Album", "Duration" in ms, "Playback Position" in s; no artwork).
public struct PlayerAnnouncement: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case playing, paused, stopped
    }

    public var player: ScriptablePlayer
    public var state: State
    public var title: String?
    public var artist: String?
    public var album: String?
    public var duration: TimeInterval?
    /// Position when announced. Spotify includes it; Music doesn't (Brim asks Music when it needs it).
    public var position: TimeInterval?
    /// Spotify's "spotify:track:…" ("Track ID"), for its cover when macOS's Now Playing is on another app (0.17.3).
    public var trackID: String?
    public var date: Date

    public init(player: ScriptablePlayer, state: State, title: String? = nil, artist: String? = nil,
                album: String? = nil, duration: TimeInterval? = nil, position: TimeInterval? = nil,
                trackID: String? = nil, date: Date) {
        self.player = player
        self.state = state
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.position = position
        self.trackID = trackID
        self.date = date
    }

    /// The notification each player posts.
    public static func notificationName(for player: ScriptablePlayer) -> String {
        switch player {
        case .spotify: "com.spotify.client.PlaybackStateChanged"
        case .music: "com.apple.Music.playerInfo"
        }
    }

    /// Reads a notification's details. Durations arrive in milliseconds ("Duration" from Spotify,
    /// "Total Time" from Music); Spotify's position arrives in seconds.
    public static func parse(player: ScriptablePlayer, userInfo: [AnyHashable: Any], at date: Date) -> PlayerAnnouncement? {
        let state: State
        switch userInfo["Player State"] as? String {
        case "Playing": state = .playing
        case "Paused": state = .paused
        case "Stopped": state = .stopped
        default: return nil
        }
        func number(_ key: String) -> Double? { (userInfo[key] as? NSNumber)?.doubleValue }
        let milliseconds = number("Duration") ?? number("Total Time")
        return PlayerAnnouncement(player: player, state: state, title: userInfo["Name"] as? String,
                                  artist: userInfo["Artist"] as? String, album: userInfo["Album"] as? String,
                                  duration: milliseconds.map { $0 / 1000 }, position: number("Playback Position"),
                                  trackID: userInfo["Track ID"] as? String, date: date)
    }

    /// Same fields as a Now Playing item's identity, so a cover seen through macOS can be matched.
    public var identity: TrackIdentity { TrackIdentity(title: title ?? "", artist: artist, album: album) }

    /// As a Now Playing item, for when Brim shows this player itself.
    public func nowPlaying(artwork: Data?) -> NowPlaying? {
        guard state != .stopped, let title, !title.isEmpty else { return nil }
        return NowPlaying(title: title, artist: artist, album: album, bundleIdentifier: player.rawValue,
                          isPlaying: state == .playing, duration: duration, elapsed: position,
                          timestamp: position == nil ? nil : date, playbackRate: 1, artwork: artwork,
                          mediaType: "kMRMediaRemoteNowPlayingInfoTypeAudio")
    }
}

/// Spotify's and Music's own announcements. Live: system notifications; tests: a fake.
@MainActor
public protocol PlayerAnnouncementsService: AnyObject {
    var announcements: AsyncStream<PlayerAnnouncement> { get }
    func start()
}

/// Which source the island shows (your research item 2, 2026-09-30).
public enum NowPlayingSource: Equatable, Sendable {
    /// The app macOS reports as Now Playing.
    case system
    /// Spotify or Music on its own, because macOS's Now Playing app is paused while this one plays.
    case player(ScriptablePlayer)
}

/// macOS keeps one Now Playing app: the last one that started playing. Pausing it doesn't hand Now Playing
/// back to Spotify, even while Spotify plays (you found this; seen live 2026-09-30). These rules pick what
/// you can actually hear. Pure, so they're unit-tested.
public enum SourceRules {
    public static func preferred(system: NowPlaying?, players: [PlayerAnnouncement],
                                 current: NowPlayingSource) -> NowPlayingSource {
        // 1. macOS's Now Playing app is playing: show it (it's the one you started last).
        if system?.isPlaying == true { return .system }
        // Nothing at all in Now Playing: nothing to replace.
        guard let system else { return .system }
        // 2. It's paused, and Spotify or Music is playing: show the one you can hear.
        let systemPlayer = ScriptablePlayer(bundleID: system.sourceBundleIdentifier)
        let audible = players.filter { $0.state == .playing && $0.player != systemPlayer }
        if let latest = audible.max(by: { $0.date < $1.date }) { return .player(latest.player) }
        // 3. Nothing plays: keep what's on screen, so pausing Spotify doesn't jump back to an old video.
        if case .player(let shown) = current,
           players.contains(where: { $0.player == shown && $0.state == .paused }) { return current }
        return .system
    }
}

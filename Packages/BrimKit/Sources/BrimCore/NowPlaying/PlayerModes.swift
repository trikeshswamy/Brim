import Foundation

/// The two players whose shuffle and repeat Brim can read and change (through their scripting interfaces).
public enum ScriptablePlayer: String, Sendable, CaseIterable {
    case spotify = "com.spotify.client"
    case music = "com.apple.Music"

    public init?(bundleID: String?) {
        guard let bundleID, let player = ScriptablePlayer(rawValue: bundleID) else { return nil }
        self = player
    }
}

public enum RepeatMode: Equatable, Sendable {
    case off
    /// The playlist or album.
    case all
    /// The current song.
    case one

    /// The button's next state: off → all → one → off where the player can say "one" (Music; Spotify through its
    /// Web API); off ↔ all where it can't (Spotify's scripting only knows on/off).
    public func next(hasOne: Bool) -> RepeatMode {
        switch self {
        case .off: .all
        case .all: hasOne ? .one : .off
        case .one: .off
        }
    }
}

/// Shuffle and repeat as the player reports them.
public struct PlayerModes: Equatable, Sendable {
    public var shuffle: Bool
    public var repeatMode: RepeatMode
    /// Spotify locks both in radio, autoplay, DJ, and Smart Shuffle; the buttons dim then.
    public var canChange: Bool
    /// ★ for the playing song: Apple Music's Favorite, or whether it's in your Spotify Liked Songs (0.18.3). Nil where
    /// the player can't say (a video, a local file, Spotify not connected).
    public var favorite: Bool?
    /// Spotify 1.3.3 lets shuffle and repeat change only while it's the app in front (its menu greys them out in the
    /// background, and its scripting answers nothing): the buttons say so on hover.
    public var changeableOnlyInFront: Bool
    /// Read from Spotify's menu: its one Repeat checkmark covers both All and One, so "on" may be either, and a press
    /// moves one step of off → all → one → off, like Spotify's own button.
    public var repeatOnMayBeOne: Bool
    /// The player reports and takes all three Repeat states (Spotify through its Web API; Music says so itself).
    public var repeatHasOne: Bool
    /// Spotify allowed Brim playback but not your Liked Songs: you connected before ★ came to Spotify (0.18.3). ★
    /// says to connect again, once.
    public var favoriteNeedsReconnect: Bool

    public init(shuffle: Bool, repeatMode: RepeatMode, canChange: Bool = true, favorite: Bool? = nil,
                changeableOnlyInFront: Bool = false, repeatOnMayBeOne: Bool = false, repeatHasOne: Bool = false,
                favoriteNeedsReconnect: Bool = false) {
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.canChange = canChange
        self.favorite = favorite
        self.changeableOnlyInFront = changeableOnlyInFront
        self.repeatOnMayBeOne = repeatOnMayBeOne
        self.repeatHasOne = repeatHasOne
        self.favoriteNeedsReconnect = favoriteNeedsReconnect
    }

    /// Shuffle and repeat as Spotify's own Playback menu shows them (Spotify 1.3.3 answers no Apple Events, 2026-10-02):
    /// a checkmark means on (Repeat's covers "all" and "one", so it reads as on or off, like its scripting did).
    /// Measured on your Mac: the items are enabled only while Spotify is in front, so in the background that's the
    /// reason, not a locked queue.
    public static func fromSpotifyMenu(shuffleChecked: Bool, repeatChecked: Bool, enabled: Bool, inFront: Bool) -> PlayerModes {
        PlayerModes(shuffle: shuffleChecked, repeatMode: repeatChecked ? .all : .off, canChange: enabled,
                    changeableOnlyInFront: !enabled && !inFront, repeatOnMayBeOne: true)
    }

    /// The player now reports everything you asked for. ★ counts only when both sides know it.
    public func matches(_ wanted: PlayerModes) -> Bool {
        shuffle == wanted.shuffle && repeatMode == wanted.repeatMode
            && (wanted.favorite == nil || favorite == nil || favorite == wanted.favorite)
    }
}

/// When Spotify or Music stops answering Brim's Apple Events, what happens to the next ones. Spotify 1.3.3 stopped
/// answering any (2026-10-02, from 01:08): each event waited its 2 s and timed out, one after another, so 35 taps on
/// Next queued for over a minute, and a Spotify coming back mid-queue would have skipped a dozen songs. Now one
/// timed-out event makes that player's next events fail at once for `pause`; then one tries again.
public struct PlayerReachability: Sendable {
    public static let pause: TimeInterval = 5
    private var quietUntil: [ScriptablePlayer: Date] = [:]

    public init() {}

    public func allows(_ player: ScriptablePlayer, at now: Date) -> Bool {
        quietUntil[player].map { now >= $0 } ?? true
    }

    public mutating func timedOut(_ player: ScriptablePlayer, at now: Date) {
        quietUntil[player] = now.addingTimeInterval(Self.pause)
    }

    public mutating func answered(_ player: ScriptablePlayer) {
        quietUntil[player] = nil
    }
}

/// Reads and changes shuffle and repeat, and controls Spotify or Music directly. Live: Apple Events
/// (Automation permission). Tests: a fake. Every call may wait for the player, so it's async and never
/// runs on the main thread in the live version.
public protocol PlayerControlsService: Sendable {
    /// `track`: the song Spotify's app announced ("spotify:track:…"), for ★ (0.18.3): Spotify's Web API can lag
    /// behind its app for a moment after a song change, and ★ must be the song you see. Music ignores it.
    func modes(of player: ScriptablePlayer, track: String?) async -> PlayerModes?
    func setShuffle(_ on: Bool, in player: ScriptablePlayer) async -> Bool
    func setRepeat(_ mode: RepeatMode, in player: ScriptablePlayer) async -> Bool
    /// ★ the playing song: Apple Music's Favorite (like the Music app, this can also add it to your library), or
    /// Spotify's Liked Songs (`track`, as for `modes`).
    func setFavorite(_ on: Bool, in player: ScriptablePlayer, track: String?) async -> Bool
    /// Play/pause, next, previous sent to the player itself: used while Brim shows it but macOS's
    /// Now Playing app is another one (commands through macOS would reach that other app).
    func perform(_ command: MediaCommand, in player: ScriptablePlayer) async -> Bool
    func seek(to position: TimeInterval, in player: ScriptablePlayer) async -> Bool
    /// The player's own position in seconds (Music doesn't announce it).
    func position(of player: ScriptablePlayer) async -> (seconds: Double, roundTrip: TimeInterval)?
    /// The player's own volume, 0–100 (Music's and Spotify's `sound volume`), apart from the Mac's: what Apple
    /// Music's own slider changes (your find, 2026-11-17). Nil when it doesn't answer.
    func appVolume(in player: ScriptablePlayer) async -> Int?
    func setAppVolume(_ level: Int, in player: ScriptablePlayer) async -> Bool
}

extension PlayerControlsService {
    public func appVolume(in player: ScriptablePlayer) async -> Int? { nil }
    public func setAppVolume(_ level: Int, in player: ScriptablePlayer) async -> Bool { false }

    /// Shuffle, repeat and ★ without Spotify's song name: Spotify's ★ then asks its Web API which song is playing.
    public func modes(of player: ScriptablePlayer) async -> PlayerModes? {
        await modes(of: player, track: nil)
    }
}

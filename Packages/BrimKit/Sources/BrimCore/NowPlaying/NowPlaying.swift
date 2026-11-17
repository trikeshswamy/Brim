import Foundation

/// What is playing right now, as reported by macOS through the helper.
public struct NowPlaying: Equatable, Sendable {
    public var title: String
    public var artist: String?
    public var album: String?
    /// The process that owns the media session (for web media this can be a browser helper).
    public var bundleIdentifier: String?
    /// The app you'd recognise, e.g. Safari for a YouTube tab. Preferred for icons.
    public var parentBundleIdentifier: String?
    public var isPlaying: Bool
    public var duration: TimeInterval?
    /// Playback position at the moment `timestamp` was taken.
    public var elapsed: TimeInterval?
    public var timestamp: Date?
    public var playbackRate: Double?
    public var artwork: Data?
    /// macOS's kind of media, e.g. `kMRMediaRemoteNowPlayingInfoTypeAudio` (music and podcasts) or `…TypeVideo`.
    public var mediaType: String?
    /// Explicit capability when a source knows it cannot seek. Nil keeps the legacy inferred behavior.
    public var supportsSeeking: Bool?

    public init(
        title: String,
        artist: String? = nil,
        album: String? = nil,
        bundleIdentifier: String? = nil,
        parentBundleIdentifier: String? = nil,
        isPlaying: Bool = false,
        duration: TimeInterval? = nil,
        elapsed: TimeInterval? = nil,
        timestamp: Date? = nil,
        playbackRate: Double? = nil,
        artwork: Data? = nil,
        mediaType: String? = nil,
        supportsSeeking: Bool? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.bundleIdentifier = bundleIdentifier
        self.parentBundleIdentifier = parentBundleIdentifier
        self.isPlaying = isPlaying
        self.duration = duration
        self.elapsed = elapsed
        self.timestamp = timestamp
        self.playbackRate = playbackRate
        self.artwork = artwork
        self.mediaType = mediaType
        self.supportsSeeking = supportsSeeking
    }

    /// ±15 s beats previous/next for videos, the Podcasts app, and anything 15 minutes or longer (PRD F2).
    /// macOS doesn't say which commands a player supports, so these are the best signals it gives. Browsers don't say
    /// "video" either: Dia reports a YouTube video with no kind and no album (your screenshot, 2026-10-01: a 14:20
    /// video got previous / next). So in a browser, media without an album counts as a video; music sites name one.
    public var prefersSkipButtons: Bool {
        if mediaType?.localizedCaseInsensitiveContains("video") == true { return true }
        if sourceBundleIdentifier == "com.apple.podcasts" { return true }
        if isFromBrowser, (album ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return true }
        return (duration ?? 0) >= 15 * 60
    }

    /// Web media: a browser plays it (or WebKit's media process, when macOS doesn't name Safari).
    public var isFromBrowser: Bool {
        guard let source = sourceBundleIdentifier?.lowercased() else { return false }
        return Self.browserPrefixes.contains { source.hasPrefix($0) }
    }

    /// Browsers by the start of their bundle ID, so betas and other channels count too.
    static let browserPrefixes = [
        "com.apple.safari", "com.apple.webkit", "company.thebrowser.", "com.google.chrome", "org.chromium.",
        "org.mozilla.", "com.microsoft.edgemac", "com.brave.browser", "com.operasoftware.", "com.vivaldi.",
        "com.kagi.kagimacos", "app.zen-browser.",
    ]

    /// The app to show as the source of this media.
    public var sourceBundleIdentifier: String? { parentBundleIdentifier ?? bundleIdentifier }

    /// Same identity = same song. Used to notice track changes.
    public var identity: TrackIdentity { TrackIdentity(title: title, artist: artist, album: album) }

    /// Playback position at `now`, worked out from the last report instead of asking again (no polling).
    /// position = elapsed + (now − timestamp) × rate, kept between 0 and the duration.
    public func position(at now: Date) -> TimeInterval? {
        guard let elapsed else { return nil }
        guard let timestamp else { return elapsed }
        let rate = isPlaying ? (playbackRate ?? 1) : 0
        let position = elapsed + now.timeIntervalSince(timestamp) * rate
        if let duration { return min(max(0, position), duration) }
        return max(0, position)
    }
}

/// The parts of a track that tell two songs apart.
public struct TrackIdentity: Hashable, Sendable {
    public var title: String
    public var artist: String?
    public var album: String?
}

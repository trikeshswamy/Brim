import AppKit
import Observation
import BrimCore

/// Now Playing state for the views.
/// Reads the service's events, sends commands, and tells the island when music starts or the song changes.
///
/// Two sources: macOS's Now Playing app (through the helper), and Spotify's and Music's own announcements.
/// macOS keeps the last app that started playing, even once it's paused, so while a paused browser holds
/// Now Playing and Spotify plays, the island shows Spotify and the buttons go to Spotify (`SourceRules`).
@Observable
public final class NowPlayingStore {
    public private(set) var item: NowPlaying?
    public private(set) var artwork: NSImage?
    /// Counts real cover changes: the kept pill flips its artwork when this changes (decision 12).
    public private(set) var artworkVersion = 0
    /// The waveform's colour, picked from the artwork once per song. Nil for black-and-white art.
    public private(set) var artworkTint: TintColor?
    /// Up to 4 of the art's colours, for the full-screen player's background. Empty for black-and-white art.
    public private(set) var artworkColors: [TintColor] = []
    public private(set) var sourceIcon: NSImage?
    /// The playing app's name, e.g. "Spotify" (for the icon's hover text).
    public private(set) var sourceName: String?
    public private(set) var availability: Availability = .starting
    public private(set) var helper = HelperStatus(processID: nil, restarts: 0)
    public private(set) var lastEventAt: Date?
    /// Shown right after a click, before the helper confirms. Cleared by the next event or after 1 s.
    public private(set) var pendingIsPlaying: Bool?
    /// Which source is on screen: macOS's Now Playing app, or Spotify/Music on its own.
    public private(set) var source: NowPlayingSource = .system
    /// A command sent straight to Spotify or Music didn't go through: ⏮ ⏯ ⏭ fade, with the reason, for 5 s (then a
    /// click tries again). Separate from shuffle/repeat reads: Spotify 1.3.3 answers no reads, but its menu works.
    public private(set) var directControlFailed = false
    @ObservationIgnored private var failedReset: Task<Void, Never>?

    @ObservationIgnored private let service: any NowPlayingService
    @ObservationIgnored private let island: IslandCoordinator
    @ObservationIgnored private let players: (any PlayerAnnouncementsService)?
    @ObservationIgnored private let controls: (any PlayerControlsService)?
    /// Spotify's covers from its Web API, for when it's shown on its own (0.17.3). Nil: never asked.
    @ObservationIgnored private let coverSource: (any SpotifyCoverService)?
    /// Songs whose cover Brim asked Spotify for (once each), and the ones still on their way.
    @ObservationIgnored private var coversAsked: Set<TrackIdentity> = []
    @ObservationIgnored private var coversComing: Set<TrackIdentity> = []
    /// The song whose cover the pill is waiting for (it keeps the last one meanwhile).
    @ObservationIgnored private var waitingCoverFor: TrackIdentity?
    /// How long a switch away from macOS's Now Playing app waits, so a buffering video doesn't flicker.
    @ObservationIgnored private let switchDelay: Duration
    /// How long Now Playing must stay empty before the music counts as gone (it blanks for 0.1–0.4 s between songs).
    @ObservationIgnored private let blankHold: Duration
    @ObservationIgnored private var blankWait: Task<Void, Never>?
    /// Another app that started playing over the music on screen, and since when (see `show`).
    @ObservationIgnored private var newcomer: (app: String, since: Date)?
    @ObservationIgnored private var newcomerCheck: Task<Void, Never>?
    /// The clock (tests move it).
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var playersListener: Task<Void, Never>?
    @ObservationIgnored private var pendingReset: Task<Void, Never>?
    @ObservationIgnored private var pendingSwitch: Task<Void, Never>?
    /// The latest item from macOS's Now Playing, even while the island shows another source.
    @ObservationIgnored private var systemItem: NowPlaying?
    @ObservationIgnored private var announcements: [ScriptablePlayer: PlayerAnnouncement] = [:]
    /// Covers seen through macOS's Now Playing (players' own announcements carry none). A few songs' worth.
    @ObservationIgnored private var covers: [TrackIdentity: Data] = [:]
    /// The cover's bytes on show (it can lag the item by up to `artworkWait` while a new song's cover comes).
    @ObservationIgnored private var shownCover: Data?
    @ObservationIgnored private var coverWait: Task<Void, Never>?

    public init(service: any NowPlayingService, island: IslandCoordinator,
                players: (any PlayerAnnouncementsService)? = nil, controls: (any PlayerControlsService)? = nil,
                coverSource: (any SpotifyCoverService)? = nil,
                switchDelay: Duration = .seconds(1), blankHold: Duration = .seconds(1)) {
        self.service = service
        self.island = island
        self.players = players
        self.controls = controls
        self.coverSource = coverSource
        self.switchDelay = switchDelay
        self.blankHold = blankHold
    }

    /// What the play/pause button shows: your click first, then the truth from macOS.
    public var isPlaying: Bool { pendingIsPlaying ?? item?.isPlaying ?? false }

    public func start() {
        guard listener == nil else { return }
        let events = service.events
        listener = Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
        service.start()
        if let players {
            let stream = players.announcements
            playersListener = Task { [weak self] in
                for await announcement in stream { self?.handle(announcement) }
            }
            players.start()
        }
    }

    public func stop() {
        service.stop()
        listener?.cancel()
        listener = nil
        playersListener?.cancel()
        playersListener = nil
    }

    // MARK: - Commands

    public func togglePlayPause() {
        Usage.note("media.playPause")
        pendingIsPlaying = !isPlaying
        pendingReset?.cancel()
        pendingReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.pendingIsPlaying = nil  // no confirmation within 1 s: show the real state again
        }
        send(.togglePlayPause)
    }

    public func nextTrack() { Usage.note("media.next"); send(.nextTrack) }
    /// ±15 s as "jump to position ± 15 s": browsers ignore macOS's skip-15 command but accept a jump
    /// (tested on YouTube in Dia, normal and private windows, 2026-09-30), and every player takes a jump.
    public func skipBackward() { Usage.note("media.skip"); skip(by: -15) }
    public func skipForward() { Usage.note("media.skip"); skip(by: 15) }

    private func skip(by seconds: TimeInterval) {
        guard let item, let position = item.position(at: .now) else { return }
        let target = position + seconds
        seek(to: item.duration.map { min(target, $0) } ?? target)
    }

    /// Brings the playing app forward, like clicking it in the Dock: it also reopens a window you closed.
    /// Checked 2026-09-30: Spotify came forward in 0.17 s; with its window closed, the window came back (~0.8 s).
    /// For web media it's the browser (macOS doesn't say which tab).
    public func openSourceApp() {
        guard let bundleID = item?.sourceBundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Jumps to `position` seconds. The next update confirms it (and re-syncs the lyrics).
    public func seek(to position: TimeInterval) {
        Usage.note("media.seek")
        let target = max(0, position)
        if case .player(let player) = source, let controls {
            Task { [weak self] in
                let sent = await controls.seek(to: target, in: player)
                self?.directControl(sent)
            }
        } else {
            Task { [service] in await service.seek(to: target) }
        }
    }
    public func previousTrack() { Usage.note("media.previous"); send(.previousTrack) }

    /// ⌘← in the full-screen player, as Apple Music does it: more than 3 s in, back to the start of the song; again
    /// (now at the start), the song before. A player that can't seek goes straight to the song before.
    public func restartOrPrevious() {
        if let position = item?.position(at: .now), position > 3, item?.supportsSeeking != false {
            seek(to: 0)
        } else {
            previousTrack()
        }
    }

    /// Which player macOS's Now Playing route reaches right now: the Now Playing app, while the island shows it.
    /// Nil while the island shows a player on its own (the route would reach the other, paused app).
    public var playerReachedThroughNowPlaying: ScriptablePlayer? {
        guard source == .system else { return nil }
        return ScriptablePlayer(bundleID: systemItem?.sourceBundleIdentifier)
    }

    /// The song Spotify's app announced last ("spotify:track:…"), for ★ (0.18.3): exactly the song Spotify is on, with
    /// no wait for its Web API to catch up after a song change.
    public var spotifyTrack: String? { announcements[.spotify]?.trackID }

    /// The music app ⌃ + volume keys turn (your ask, 2026-11-17: Spotify and a meeting in Dia at once): the one on
    /// screen if it's Music or Spotify; else whichever of them is playing in the background (its own announcements);
    /// nil when neither plays. Never a browser: those keep the Mac's volume.
    public var musicApp: ScriptablePlayer? {
        if let shown = ScriptablePlayer(bundleID: item?.sourceBundleIdentifier) { return shown }
        let playing = announcements.values.filter { $0.state == .playing }.map(\.player)
        return playing.contains(.spotify) ? .spotify : playing.first
    }

    /// Shuffle and repeat the way Control Center sets them (for Music; see `PlayerModesStore`).
    public func setShuffleThroughNowPlaying(_ on: Bool) async { await service.setShuffle(on) }
    public func setRepeatThroughNowPlaying(_ mode: RepeatMode) async { await service.setRepeat(mode) }

    /// Commands go where the island points: through macOS's Now Playing, or straight to Spotify/Music when
    /// the island shows it on its own (through macOS they'd reach the paused app instead).
    private func send(_ command: MediaCommand) {
        if case .player(let player) = source, let controls {
            Task { [weak self] in
                let sent = await controls.perform(command, in: player)
                self?.directControl(sent)
            }
        } else {
            Task { [service] in await service.perform(command) }
        }
    }

    private func directControl(_ sent: Bool) {
        failedReset?.cancel()
        directControlFailed = !sent
        guard !sent else { return }
        failedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(PlayerReachability.pause))
            guard !Task.isCancelled else { return }
            self?.directControlFailed = false
        }
    }

    // MARK: - Events

    /// Internal so tests can feed events directly.
    func handle(_ event: NowPlayingEvent) {
        lastEventAt = .now
        switch event {
        case .item(let next):
            availability = .ready  // the helper sent something: it works
            // Empty only counts once it lasts: between songs Now Playing blanks for 0.1–0.4 s, and showing that made
            // the pill blink and the next song look like music starting (your report, 2026-10-02).
            if next == nil, systemItem != nil {
                if blankWait == nil { blankWait = Task { [weak self, blankHold] in
                    try? await Task.sleep(for: blankHold)
                    guard !Task.isCancelled, let self else { return }
                    self.blankWait = nil
                    self.systemItem = nil
                    self.reconsider()
                } }
                return
            }
            blankWait?.cancel()
            blankWait = nil
            systemItem = next
            if let next, let cover = next.artwork { remember(cover, for: next.identity) }
            reconsider()
        case .availability(let value):
            availability = value
            // The helper is down: what it showed can't be trusted any more. Spotify and Music announcements still
            // show (they don't need it); with nothing else, the pill steps away and the Music tab says why (+ Retry).
            if case .unavailable = value, systemItem != nil {
                blankWait?.cancel()
                blankWait = nil
                systemItem = nil
                reconsider()
            }
        case .helper(let status): helper = status
        }
    }

    /// What Spotify's Web API said as Brim started (0.18.2). Spotify announces itself only on its next change, so until
    /// then Brim couldn't know it was playing behind a paused tab. Its own announcement always wins over this.
    public func seed(_ announcement: PlayerAnnouncement) {
        guard announcements[announcement.player] == nil else { return }
        handle(announcement)
    }

    #if DEBUG
    /// Debug renders only: show `item` as if macOS's Now Playing had reported it.
    public func debugPretend(_ item: NowPlaying) { handle(.item(item)) }
    #endif

    /// Internal so tests can feed announcements directly.
    func handle(_ announcement: PlayerAnnouncement) {
        announcements[announcement.player] = announcement
        reconsider()
    }

    /// Shows the source the rules pick. Coming back to macOS's Now Playing app is immediate (you just started
    /// it); leaving it waits `switchDelay`, then asks the rules again.
    private func reconsider() {
        let wanted = SourceRules.preferred(system: systemItem, players: Array(announcements.values), current: source)
        // The app already on screen, now through its own announcements (macOS's Now Playing moved to a paused tab):
        // nothing you can see changes, so nothing to wait for.
        let alreadyShown: Bool = {
            guard case .player(let player) = wanted else { return false }
            return ScriptablePlayer(bundleID: item?.sourceBundleIdentifier) == player
        }()
        if wanted == source || wanted == .system || alreadyShown {
            pendingSwitch?.cancel()
            pendingSwitch = nil
            if wanted != source { directControlFailed = false }
            source = wanted
        } else if pendingSwitch == nil {
            pendingSwitch = Task { [weak self, switchDelay] in
                try? await Task.sleep(for: switchDelay)
                guard !Task.isCancelled, let self else { return }
                self.pendingSwitch = nil
                self.source = SourceRules.preferred(system: self.systemItem, players: Array(self.announcements.values),
                                                    current: self.source)
                self.show()
                self.askPositionIfMissing()
            }
        }
        show()
    }

    private func show() {
        let next: NowPlaying?
        switch source {
        case .system:
            next = systemItem
        case .player(let player):
            let announcement = announcements[player]
            if let announcement { askForCover(announcement) }
            next = announcement?.nowPlaying(artwork: announcement.flatMap { covers[$0.identity] }) ?? systemItem
        }
        // Another app that starts playing over music on screen replaces it only once it has played `switchDelay`:
        // a Dia tab plays for under a second on its own and macOS hands it Now Playing (15:40 on 2026-10-02, "A site
        // is playing media" took your Spotify song's place for 1.7 s). A video you start keeps playing, so it shows.
        if let next, let item, next.isPlaying, item.isPlaying, let app = next.sourceBundleIdentifier,
           app != item.sourceBundleIdentifier {
            if newcomer?.app != app {
                newcomer = (app, now())
                newcomerCheck?.cancel()
                newcomerCheck = nil
            }
            if let since = newcomer?.since, now().timeIntervalSince(since) < Self.seconds(switchDelay) - 0.01 {
                if newcomerCheck == nil {
                    newcomerCheck = Task { [weak self, switchDelay] in
                        try? await Task.sleep(for: switchDelay)
                        guard !Task.isCancelled, let self else { return }
                        self.newcomerCheck = nil
                        if self.newcomer != nil { self.show() }  // still playing? then it shows now
                    }
                }
                return
            }
        }
        if let waiting = newcomer, next?.sourceBundleIdentifier != waiting.app {
            let played = Int(now().timeIntervalSince(waiting.since) * 1000)
            Log.nowPlaying.notice("Kept the music on screen: \(waiting.app, privacy: .public) played for \(played, privacy: .public) ms")
        }
        newcomer = nil
        newcomerCheck?.cancel()
        newcomerCheck = nil
        apply(next)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }

    /// Music doesn't announce its position; ask it once, so the progress bar and lyrics have a place to start.
    private func askPositionIfMissing() {
        guard case .player(let player) = source, announcements[player]?.position == nil, let controls else { return }
        Task { [weak self] in
            guard let answer = await controls.position(of: player), let self,
                  self.source == .player(player), var latest = self.announcements[player] else { return }
            latest.position = answer.seconds
            latest.date = .now
            self.announcements[player] = latest
            self.show()
        }
    }

    /// Spotify shown on its own (macOS's Now Playing is on another app, 9 minutes once on 2026-10-02): its announcements
    /// carry no cover, so Brim asks Spotify's Web API, once per song (0.17.3, your OK). ~0.4 s; ~1.5 s the first time
    /// after launch, while the sign-in renews.
    private func askForCover(_ announcement: PlayerAnnouncement) {
        let identity = announcement.identity
        guard let coverSource, announcement.state != .stopped, let uri = announcement.trackID,
              covers[identity] == nil, !coversAsked.contains(identity) else { return }
        if coversAsked.count >= 200 { coversAsked.removeAll() }  // a few hours of songs is plenty
        coversAsked.insert(identity)
        coversComing.insert(identity)
        let asked = Date()
        Task { [weak self] in
            let cover = await coverSource.cover(forTrack: uri)
            guard let self else { return }
            self.coversComing.remove(identity)
            guard let cover else { return }
            Log.nowPlaying.notice("Cover from Spotify's Web API in \(Int(Date().timeIntervalSince(asked) * 1000), privacy: .public) ms")
            self.remember(cover, for: identity)
            if case .player = self.source, self.item?.identity == identity { self.show() }
        }
    }

    private func remember(_ cover: Data, for identity: TrackIdentity) {
        if covers.count >= 8, covers[identity] == nil { covers.removeAll() }  // a few songs is plenty
        covers[identity] = cover
    }

    private func apply(_ next: NowPlaying?) {
        let previous = item
        // A pause report a moment old would step the progress bar and lyrics back (your video, 2026-10-07).
        let next = next.map { PauseRules.settled($0, after: previous, at: now()) }
        item = next
        pendingIsPlaying = nil
        island.setMedia(Self.presence(of: next, current: island.media))

        updateCover(for: next, songChanged: next?.identity != previous?.identity)
        if next?.sourceBundleIdentifier != previous?.sourceBundleIdentifier {
            sourceIcon = Self.appIcon(for: next?.sourceBundleIdentifier)
            sourceName = Self.appName(for: next?.sourceBundleIdentifier)
            Log.nowPlaying.notice("On screen: \(next?.sourceBundleIdentifier ?? "nothing", privacy: .public)")
        }
        // Music never widens the island (0.17.4, your pick, like the iPhone's Dynamic Island): music starting shows the
        // pill if you keep music visible, a song change turns its cover (decision 12), and the title is in the open island.
    }

    /// Why Brim can't see what's playing (the helper keeps stopping, or is missing), or nil when it can.
    public var unavailableReason: String? {
        if case .unavailable(let reason) = availability { return reason }
        return nil
    }

    /// Retry now (the Music tab's button): the helper starts again without waiting out its backoff.
    public func retryHelper() {
        availability = .starting
        service.retryNow()
    }

    /// How long a new song keeps the last cover while its own is on the way, so the pill flips once, to the right one.
    static let artworkWait: Duration = .milliseconds(500)
    /// The same while Spotify's Web API fetches it (0.17.3): ~0.4 s, ~1.5 s the first time after launch.
    static let fetchedArtworkWait: Duration = .seconds(2)

    private func updateCover(for next: NowPlaying?, songChanged: Bool) {
        let cover = next?.artwork
        // Already waiting for this song's cover: the same song again without it (a position update, another app's
        // Now Playing changing) changes nothing; before, it showed the placeholder early, and the pill flipped twice.
        if cover == nil, let next, waitingCoverFor == next.identity { return }
        coverWait?.cancel()
        waitingCoverFor = nil
        guard cover != shownCover else { return }
        if songChanged, cover == nil, shownCover != nil, let next {
            let wait = coversComing.contains(next.identity) ? Self.fetchedArtworkWait : Self.artworkWait
            waitingCoverFor = next.identity
            coverWait = Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, let self else { return }
                self.waitingCoverFor = nil
                guard self.item?.identity == next.identity else { return }
                self.showCover(self.item?.artwork)
            }
        } else {
            showCover(cover)
        }
    }

    private func showCover(_ cover: Data?) {
        guard cover != shownCover else { return }
        shownCover = cover
        artwork = cover.flatMap { NSImage(data: $0) }
        let image = artwork?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        artworkColors = image.map { ArtworkPalette.colors(of: $0, count: 4) } ?? []
        artworkTint = artworkColors.first
        artworkVersion += 1
    }

    /// Playing, paused (keeping the moment it was first paused, for the 1-minute pill rule), or nothing.
    private static func presence(of item: NowPlaying?, current: MediaPresence) -> MediaPresence {
        guard let item else { return .none }
        if item.isPlaying { return .playing }
        if case .paused = current { return current }
        return .paused(since: .now)
    }

    private static func appName(for bundleID: String?) -> String? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private static func appIcon(for bundleID: String?) -> NSImage? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

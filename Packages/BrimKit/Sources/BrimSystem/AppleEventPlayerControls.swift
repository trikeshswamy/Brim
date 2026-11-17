import AppKit
import Foundation
import BrimCore

/// Shuffle and repeat for Spotify and Music, sent as raw Apple Events: the same messages AppleScript sends,
/// without compiling a script. An actor, so waiting for the player never blocks the island.
///
/// - Needs Automation for each app ("Brim wants to control Spotify"); you allowed both on 2026-09-29.
/// - Never talks to a player that isn't running, because an Apple Event would launch it.
/// - Property codes come from each app's scripting dictionary (`sdef`): Spotify `pShu`, `pRep`, `pReE`
///   (its "shuffling enabled" and "repeating enabled" share `pReE`); Music `pShE`, `pRpt` (`kRpO`/`kAll`/`kRp1`).
public actor AppleEventPlayerControls: PlayerControlsService, QueueService, HistoryService {
    /// Which player stopped answering, and until when its next events fail at once.
    private var reachability = PlayerReachability()
    /// Whether Spotify answers its scripting. Nil until checked. 1.3.3 doesn't (2026-10-02); its menu then works only
    /// while Spotify is in front, and nothing else reaches it from the background (its window shows Accessibility
    /// no player buttons). Scripting works from anywhere, so it's used again as soon as Spotify answers. Checked when
    /// Brim starts and each time Spotify launches (`checkSpotifyScripting`), never on the way to the island.
    private var spotifyScripting: Bool?

    /// One question to a running Spotify's scripting (up to 2 s), off the island's path.
    public func checkSpotifyScripting() async {
        guard running(.spotify) != nil else { return }
        reachability.answered(.spotify)  // a fresh launch gets a fresh try
        spotifyScripting = (try? get("pShu", from: .spotify)) != nil
        Log.nowPlaying.notice("Spotify's scripting answers: \(self.spotifyScripting == true, privacy: .public)")
    }

    /// Spotify's Web API, once you've signed in (Settings → Media & Lyrics): all three Repeat states, from anywhere.
    private let spotifyWeb: SpotifyWebAPI?
    private let catalog = AppleCatalogLookup()

    public init(spotifyWeb: SpotifyWebAPI? = nil) {
        self.spotifyWeb = spotifyWeb
    }

    public func modes(of player: ScriptablePlayer, track: String?) async -> PlayerModes? {
        guard player == .spotify, isRunning(player), let spotifyWeb, await spotifyWeb.isUsable else {
            return await readModes(of: player)
        }
        // ★ through Spotify's Web API (0.18.3), asked alongside whichever way Shuffle & Repeat answer: ★ keeps working
        // when Spotify's menu stands in for them.
        async let liked = spotifyWeb.liked(track)
        guard var modes = await readModes(of: player) else { return nil }
        modes.favorite = await liked
        modes.favoriteNeedsReconnect = await spotifyWeb.likedSongsNeedReconnect
        return modes
    }

    private func readModes(of player: ScriptablePlayer) async -> PlayerModes? {
        guard let running = running(player) else { return nil }
        if player == .spotify {
            // Its Web API once you've signed in (exact, from anywhere); its scripting if it answers again; else its menu.
            if let spotifyWeb, await spotifyWeb.isUsable, let modes = await spotifyWeb.modes() { return modes }
            if spotifyScripting == true, let modes = spotifyModesByScript() { return modes }
            if let modes = SpotifyPlaybackMenu.modes(pid: running.processIdentifier) { return modes }
            guard spotifyScripting == nil else { return nil }  // known not to answer: no 2-s wait
        }
        do {
            switch player {
            case .spotify:
                let shuffle = try get("pShu", from: player).booleanValue
                let repeating = try get("pRep", from: player).booleanValue
                let allowed = (try? get("pReE", from: player).booleanValue) ?? true
                return PlayerModes(shuffle: shuffle, repeatMode: repeating ? .all : .off, canChange: allowed)
            case .music:
                let shuffle = try get("pShE", from: player).booleanValue
                let repeating: RepeatMode = switch try get("pRpt", from: player).enumCodeValue {
                case Self.code("kRp1"): .one
                case Self.code("kAll"): .all
                default: .off
                }
                let favorite = try? get(Self.trackPropertySpecifier("pLov"), from: player).booleanValue
                return PlayerModes(shuffle: shuffle, repeatMode: repeating, favorite: favorite)
            }
        } catch {
            if !Self.isQuiet(error) {
                Log.nowPlaying.error("Reading shuffle/repeat failed: \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
    }

    public func setShuffle(_ on: Bool, in player: ScriptablePlayer) async -> Bool {
        guard let running = running(player) else { return false }
        if player == .spotify, let spotifyWeb, await spotifyWeb.isUsable, await spotifyWeb.setShuffle(on) { return true }
        if player == .spotify, spotifyScripting != true, SpotifyPlaybackMenu.setShuffle(on, pid: running.processIdentifier) {
            return true
        }
        return (try? set(player == .spotify ? "pShu" : "pShE", to: NSAppleEventDescriptor(boolean: on), in: player)) != nil
    }

    public func setRepeat(_ mode: RepeatMode, in player: ScriptablePlayer) async -> Bool {
        guard let running = running(player) else { return false }
        if player == .spotify, let spotifyWeb, await spotifyWeb.isUsable, await spotifyWeb.setRepeat(mode) { return true }
        // Spotify without its scripting: one press of its menu's Repeat, one step, like its own button.
        if player == .spotify, spotifyScripting != true, SpotifyPlaybackMenu.pressRepeat(pid: running.processIdentifier) {
            return true
        }
        let value: NSAppleEventDescriptor = switch player {
        case .spotify: NSAppleEventDescriptor(boolean: mode != .off)
        case .music: NSAppleEventDescriptor(enumCode: Self.code(mode == .one ? "kRp1" : mode == .all ? "kAll" : "kRpO"))
        }
        return (try? set(player == .spotify ? "pRep" : "pRpt", to: value, in: player)) != nil
    }

    /// ★: Music's `set favorited of current track to <on>` (`pLov` of `pTrk`); Spotify's Liked Songs through its Web
    /// API (0.18.3), as Spotify's app offers no other way.
    public func setFavorite(_ on: Bool, in player: ScriptablePlayer, track: String?) async -> Bool {
        guard isRunning(player) else { return false }
        switch player {
        case .spotify:
            guard let spotifyWeb, await spotifyWeb.isUsable else { return false }
            return await spotifyWeb.setLiked(on, track: track)
        case .music:
            return (try? set(Self.trackPropertySpecifier("pLov"), to: NSAppleEventDescriptor(boolean: on), in: player)) != nil
        }
    }

    /// Play/pause, next, previous sent straight to the player (`spfy`/`hook` + `PlPs`, `Play`, `Paus`, `Next`,
    /// `Prev` from each app's dictionary). ±15 s is a seek, not a command.
    /// Spotify's shuffle and repeat through its scripting; nil (and noted) when it doesn't answer.
    private func spotifyModesByScript() -> PlayerModes? {
        do {
            let shuffle = try get("pShu", from: .spotify).booleanValue
            let repeating = try get("pRep", from: .spotify).booleanValue
            let allowed = (try? get("pReE", from: .spotify).booleanValue) ?? true
            return PlayerModes(shuffle: shuffle, repeatMode: repeating ? .all : .off, canChange: allowed)
        } catch {
            spotifyScripting = false
            return nil
        }
    }

    /// Spotify gets its own Playback menu first (`SpotifyPlaybackMenu`): version 1.3.3 answers no Apple Events, and the
    /// menu answers at once.
    public func perform(_ command: MediaCommand, in player: ScriptablePlayer) async -> Bool {
        guard let running = running(player) else { return false }
        if player == .spotify, SpotifyPlaybackMenu.press(command, pid: running.processIdentifier) {
            Log.nowPlaying.notice("Spotify: pressed its Playback menu (\(String(describing: command), privacy: .public))")
            return true
        }
        guard let id = Self.eventID(for: command) else { return false }
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: Self.code(player == .spotify ? "spfy" : "hook"),
                                                      eventID: Self.code(id),
                                                      targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: player.rawValue),
                                                      returnID: AEReturnID(kAutoGenerateReturnID),
                                                      transactionID: AETransactionID(kAnyTransactionID))
        do {
            _ = try send(event, to: player)
            return true
        } catch {
            if !Self.isQuiet(error) {
                Log.nowPlaying.error("\(id, privacy: .public) to \(player.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            return false
        }
    }

    /// `set player position to <seconds>`.
    public func seek(to position: TimeInterval, in player: ScriptablePlayer) async -> Bool {
        guard isRunning(player) else { return false }
        return (try? set("pPos", to: NSAppleEventDescriptor(double: max(0, position)), in: player)) != nil
    }

    private static func eventID(for command: MediaCommand) -> String? {
        switch command {
        case .play: "Play"
        case .pause: "Paus"
        case .togglePlayPause: "PlPs"
        case .nextTrack: "Next"
        case .previousTrack: "Prev"
        case .toggleShuffle, .toggleRepeat, .skipBackward15, .skipForward15: nil
        }
    }

    /// The player's own position in seconds ("player position", `pPos` in both apps), with how long the ask took.
    /// Used to check (and, if needed, correct) the position macOS's Now Playing reports.
    public func position(of player: ScriptablePlayer) async -> (seconds: Double, roundTrip: TimeInterval)? {
        guard isRunning(player) else { return nil }
        let started = Date()
        guard let value = try? get("pPos", from: player) else { return nil }
        return (value.doubleValue, Date().timeIntervalSince(started))
    }

    // MARK: - Apple Events

    // MARK: Spotify for free (2026-10-29)

    /// What Spotify is playing, from its own scripting: no Client ID, no Premium, nothing over the network.
    public func spotifyAnnouncementByScript() -> PlayerAnnouncement? {
        guard isRunning(.spotify), spotifyScripting != false,
              let stateCode = (try? get("pPlS", from: .spotify))?.enumCodeValue else { return nil }
        let state: PlayerAnnouncement.State = switch stateCode {
        case Self.code("kPSP"): .playing
        case Self.code("kPSp"): .paused
        default: .stopped
        }
        func text(_ property: String) -> String? { (try? get(Self.trackPropertySpecifier(property), from: .spotify))?.stringValue }
        // Spotify's scripting says seconds, but answers in milliseconds.
        let duration = (try? get(Self.trackPropertySpecifier("pDur"), from: .spotify)).map { Double($0.int32Value) / 1000 }
        let position = (try? get("pPos", from: .spotify))?.doubleValue
        return PlayerAnnouncement(player: .spotify, state: state, title: text("pnam"), artist: text("pArt"), album: text("pAlb"),
                                  duration: duration, position: position, trackID: text("ID  "), date: Date())
    }

    /// The playing song's cover address, from Spotify's scripting (only Spotify's image server), if it's still `uri`.
    public func spotifyCoverURL(for uri: String) -> URL? {
        guard isRunning(.spotify), spotifyScripting != false,
              (try? get(Self.trackPropertySpecifier("ID  "), from: .spotify))?.stringValue == uri,
              let text = (try? get(Self.trackPropertySpecifier("aUrl"), from: .spotify))?.stringValue,
              let url = URL(string: text), url.host == "i.scdn.co" else { return nil }
        return url
    }

    // MARK: Queue (2026-10-29)

    public func queue(of player: ScriptablePlayer) async -> PlayerQueue {
        guard isRunning(player) else { return .empty }
        switch player {
        case .spotify:
            guard let spotifyWeb, await spotifyWeb.isUsable else { return .spotifyNotConnected }
            return await spotifyWeb.queue()
        case .music:
            let queue = musicQueue()
            guard queue == .musicLibraryOnly else { return queue }
            // Streaming an album that isn't in your Library: Apple's public catalog has its order.
            func text(_ property: String) -> String? { (try? get(Self.trackPropertySpecifier(property), from: .music))?.stringValue }
            guard let title = text("pnam"), let artist = text("pArt"), let album = text("pAlb"), !album.isEmpty else { return queue }
            // Shuffle on: the album's order isn't what plays next.
            if (try? get("pShE", from: .music))?.booleanValue == true { return .shuffled(source: album) }
            let number = (try? get(Self.trackPropertySpecifier("pTrN"), from: .music)).map { Int($0.int32Value) }
            let items = await catalog.upNext(title: title, artist: artist, album: album, trackNumber: number)
            return items.isEmpty ? queue : .items(source: album, items)
        }
    }

    public func play(_ item: QueueItem, position: Int, in player: ScriptablePlayer) async -> Bool {
        guard isRunning(player) else { return false }
        switch player {
        case .spotify:
            guard let spotifyWeb else { return false }
            return await spotifyWeb.play(item, position: position)
        case .music:
            // The list is what Music plays next, in order, so the song is `position + 1` songs ahead: skip to it,
            // one skip at a time. `play track <n> of current playlist` (used before) dropped the playlist and started
            // an unrelated song (your video, 2026-10-30); a catalog album can't be told to play a song at all.
            // Quietly (your ask, 2026-11-17: you heard each song in between start): Music's own volume is 0 while it
            // skips, then back where it was. The Mac's volume and other apps are never touched.
            let volume = await appVolume(in: .music)
            if let volume, volume > 0 { _ = await setAppVolume(0, in: .music) }
            var skipped = true
            for _ in 0...position {
                guard await perform(.nextTrack, in: player) else { skipped = false; break }
                try? await Task.sleep(for: .milliseconds(120))
            }
            if let volume, volume > 0 {
                try? await Task.sleep(for: .milliseconds(250))  // the last skip lands before the sound comes back
                _ = await setAppVolume(volume, in: .music)
            }
            return skipped
        }
    }

    /// Music's or Spotify's own volume (`pVol`, 0–100), apart from the Mac's.
    public func appVolume(in player: ScriptablePlayer) async -> Int? {
        guard isRunning(player), let value = try? get("pVol", from: player) else { return nil }
        let level = Int(value.int32Value)
        return (0...100).contains(level) ? level : nil
    }

    public func setAppVolume(_ level: Int, in player: ScriptablePlayer) async -> Bool {
        guard isRunning(player) else { return false }
        return (try? set("pVol", to: NSAppleEventDescriptor(int32: Int32(min(max(level, 0), 100))), in: player)) != nil
    }

    /// A song's artwork in Music's current playlist (`raw data of artwork 1 of track <n>`): for Up Next's covers.
    public func cover(of item: QueueItem, in player: ScriptablePlayer) async -> Data? {
        guard player == .music, let index = item.musicIndex, isRunning(player) else { return nil }
        let track = Self.elementSpecifier("cTrk", index: index, of: Self.propertySpecifier("pPla"))
        let art = Self.elementSpecifier("cArt", index: 1, of: track)
        let data = (try? get(Self.propertySpecifier("pRaw", of: art), from: .music))?.data
        return data?.isEmpty == false ? data : nil
    }

    // MARK: History (2026-10-29)

    public func currentSongID(in player: ScriptablePlayer) async -> String? {
        guard isRunning(player) else { return nil }
        return (try? get(Self.trackPropertySpecifier(player == .spotify ? "ID  " : "pPIS"), from: player))?.stringValue
    }

    /// Plays a song from History in its app. Spotify: `play track <uri>` (works without Premium). Music: the song in
    /// your Library by its persistent ID; a song streamed from outside your Library opens its catalog page instead.
    public func play(_ entry: HistoryEntry, in player: ScriptablePlayer) async -> Bool {
        guard isRunning(player) else { return false }
        switch player {
        case .spotify:
            guard let id = entry.songID, PlayHistoryRules.isValidSongID(id, for: .spotify) else { return false }
            let event = NSAppleEventDescriptor.appleEvent(withEventClass: Self.code("spfy"), eventID: Self.code("PCtx"),
                                                          targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: player.rawValue),
                                                          returnID: AEReturnID(kAutoGenerateReturnID),
                                                          transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(NSAppleEventDescriptor(string: id), forKeyword: Self.code("----"))
            return (try? send(event, to: player)) != nil
        case .music:
            if let id = entry.songID, PlayHistoryRules.isValidSongID(id, for: .music) {
                // The ID is checked to be hex only, so nothing else reaches the script.
                let source = "tell application \"Music\" to play (first track of library playlist 1 whose persistent ID is \"\(id)\")"
                let played = await MainActor.run {
                    var error: NSDictionary?
                    NSAppleScript(source: source)?.executeAndReturnError(&error)
                    return error == nil
                }
                if played { return true }
            }
            guard let page = await catalog.songPage(title: entry.title, artist: entry.artist ?? ""),
                  var parts = URLComponents(url: page, resolvingAgainstBaseURL: false), parts.host == "music.apple.com" else { return false }
            parts.scheme = "music"
            return parts.url.map { NSWorkspace.shared.open($0) } ?? false
        }
    }

    /// Music has no Up Next for other apps: the rest of the playlist or album playing is the honest answer, unless
    /// Shuffle is on (its order isn't shared). Four questions, each answered for the whole playlist at once.
    private func musicQueue() -> PlayerQueue {
        let playlist = Self.propertySpecifier("pPla")
        // Streaming an album that isn't in your Library, Music has no current playlist to share (checked 2026-10-29:
        // "Nobody Wants This: Season 3" from Apple Music).
        guard let source = (try? get(Self.propertySpecifier("pnam", of: playlist), from: .music))?.stringValue else {
            return .musicLibraryOnly
        }
        if (try? get("pShE", from: .music))?.booleanValue == true { return .shuffled(source: source) }
        guard let current = (try? get(Self.trackPropertySpecifier("pPIS"), from: .music))?.stringValue else { return .empty }
        let currentAlbum = (try? get(Self.trackPropertySpecifier("pAlb"), from: .music))?.stringValue
        let tracks = Self.everySpecifier("cTrk", of: playlist)
        func list(_ property: String) -> [String] {
            guard let value = try? get(Self.propertySpecifier(property, of: tracks), from: .music) else { return [] }
            return (0..<value.numberOfItems).map { value.atIndex($0 + 1)?.stringValue ?? "" }
        }
        let items = QueueRules.upNext(ids: list("pPIS"), titles: list("pnam"), artists: list("pArt"), albums: list("pAlb"),
                                      current: current, currentAlbum: currentAlbum)
        return items.isEmpty ? .empty : .items(source: source, items)
    }

    /// "every <class> of <container>".
    private static func everySpecifier(_ elementClass: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let specifier = NSAppleEventDescriptor.record().coerce(toDescriptorType: code("obj "))!
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: code(elementClass)), forKeyword: code("want"))
        specifier.setDescriptor(NSAppleEventDescriptor(enumCode: code("indx")), forKeyword: code("form"))
        var all = code("all ")  // kAEAll, stored as a native number like every four-letter code
        specifier.setDescriptor(NSAppleEventDescriptor(descriptorType: code("abso"), bytes: &all, length: 4)!,
                                forKeyword: code("seld"))
        specifier.setDescriptor(container, forKeyword: code("from"))
        return specifier
    }

    /// "<class> <index> of <container>" (1-based).
    private static func elementSpecifier(_ elementClass: String, index: Int, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let specifier = NSAppleEventDescriptor.record().coerce(toDescriptorType: code("obj "))!
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: code(elementClass)), forKeyword: code("want"))
        specifier.setDescriptor(NSAppleEventDescriptor(enumCode: code("indx")), forKeyword: code("form"))
        specifier.setDescriptor(NSAppleEventDescriptor(int32: Int32(index)), forKeyword: code("seld"))
        specifier.setDescriptor(container, forKeyword: code("from"))
        return specifier
    }

    private func isRunning(_ player: ScriptablePlayer) -> Bool { running(player) != nil }

    private func running(_ player: ScriptablePlayer) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: player.rawValue).first
    }

    /// `get <property> of application`
    private func get(_ property: String, from player: ScriptablePlayer) throws -> NSAppleEventDescriptor {
        try get(Self.propertySpecifier(property), from: player)
    }

    private func get(_ specifier: NSAppleEventDescriptor, from player: ScriptablePlayer) throws -> NSAppleEventDescriptor {
        let event = Self.event("getd", to: player)
        event.setParam(specifier, forKeyword: Self.code("----"))
        let reply = try send(event, to: player)
        guard let value = reply.paramDescriptor(forKeyword: Self.code("----")) else { throw ControlsError.noValue }
        return value
    }

    /// `set <property> of application to <value>`
    private func set(_ property: String, to value: NSAppleEventDescriptor, in player: ScriptablePlayer) throws {
        try set(Self.propertySpecifier(property), to: value, in: player)
    }

    private func set(_ specifier: NSAppleEventDescriptor, to value: NSAppleEventDescriptor, in player: ScriptablePlayer) throws {
        let event = Self.event("setd", to: player)
        event.setParam(specifier, forKeyword: Self.code("----"))
        event.setParam(value, forKeyword: Self.code("data"))
        _ = try send(event, to: player)
    }

    /// Every Apple Event goes through here, waiting up to 2 s for the reply. After one times out, the player's next
    /// events fail at once for a few seconds instead of each waiting in line (`PlayerReachability`).
    private func send(_ event: NSAppleEventDescriptor, to player: ScriptablePlayer) throws -> NSAppleEventDescriptor {
        guard reachability.allows(player, at: .now) else { throw ControlsError.notAnswering }
        do {
            let reply = try event.sendEvent(options: [.waitForReply], timeout: 2)
            reachability.answered(player)
            return reply
        } catch {
            if (error as NSError).code == Int(errAETimeout) {
                reachability.timedOut(player, at: .now)
                Log.nowPlaying.error("\(player.rawValue, privacy: .public) didn't answer within 2 s: its next events fail at once for \(Int(PlayerReachability.pause), privacy: .public) s")
            }
            throw error
        }
    }

    /// Already logged once by `send`: a timeout, or an event skipped while the player isn't answering.
    private static func isQuiet(_ error: Error) -> Bool {
        if case ControlsError.notAnswering? = error as? ControlsError { return true }
        return (error as NSError).code == Int(errAETimeout)
    }

    private static func event(_ id: String, to player: ScriptablePlayer) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor.appleEvent(withEventClass: code("core"), eventID: code(id),
                                          targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: player.rawValue),
                                          returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
    }

    /// "property <code> of application": want = property, form = property ID, key = the code, from = the app.
    private static func propertySpecifier(_ property: String, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        let specifier = NSAppleEventDescriptor.record().coerce(toDescriptorType: code("obj "))!
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: code("prop")), forKeyword: code("want"))
        specifier.setDescriptor(NSAppleEventDescriptor(enumCode: code("prop")), forKeyword: code("form"))
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: code(property)), forKeyword: code("seld"))
        specifier.setDescriptor(container, forKeyword: code("from"))
        return specifier
    }

    /// "property <code> of current track of application" (Music: `pTrk`).
    private static func trackPropertySpecifier(_ property: String) -> NSAppleEventDescriptor {
        propertySpecifier(property, of: propertySpecifier("pTrk"))
    }

    /// "pShu" → the four-character code Apple Events use.
    static func code(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    private enum ControlsError: Error { case noValue, notAnswering }
}

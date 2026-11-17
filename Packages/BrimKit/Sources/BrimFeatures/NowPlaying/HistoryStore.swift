import AppKit
import Observation
import BrimCore

/// History for the full-screen queue (your picks, 2026-10-29): every song you play, kept per app (the last 50 each,
/// on your Mac), shown for the app that's playing. A song joins once it's played 5 s and the next one starts, so the
/// playing song is never in its own History (like Apple Music's).
@Observable
public final class HistoryStore {
    /// Per app (bundle ID), oldest first.
    public private(set) var byApp: [String: [HistoryEntry]]
    /// The row being started: it shows a spinner until the player moves.
    public private(set) var starting: UUID?

    @ObservationIgnored private let service: HistoryService
    @ObservationIgnored private let file: HistoryFile
    @ObservationIgnored private let nowPlaying: NowPlayingStore
    @ObservationIgnored private var started = false
    /// The song playing now: it joins History when the next one starts.
    @ObservationIgnored private var playing: (app: String, identity: TrackIdentity, entry: HistoryEntry, since: Date)?
    @ObservationIgnored private var askingID: Task<Void, Never>?

    public init(service: HistoryService, file: HistoryFile, nowPlaying: NowPlayingStore) {
        self.service = service
        self.file = file
        self.nowPlaying = nowPlaying
        byApp = file.load()
    }

    /// Follows Now Playing from now on, whether or not the full-screen player is open.
    public func start() {
        guard !started else { return }
        started = true
        observe { [weak self] in
            guard let self else { return }
            self.follow(self.nowPlaying.item)
        }
    }

    /// History for the app that's playing, newest at the bottom (just above Up Next).
    public func entries(for app: String?) -> [HistoryEntry] {
        app.flatMap { byApp[$0] } ?? []
    }

    public func clear(app: String?) {
        guard let app, byApp[app] != nil else { return }
        byApp[app] = nil
        file.save(byApp)
    }

    public func play(_ entry: HistoryEntry, app: String?) async {
        guard let player = ScriptablePlayer(bundleID: app), starting == nil else { return }
        starting = entry.id
        _ = await service.play(entry, in: player)
        try? await Task.sleep(for: .milliseconds(700))
        starting = nil
    }

    /// Internal so tests can drive it directly.
    ///
    /// The cover is the song's own (`item.artwork`), never the one the island shows: when a song changes, the island
    /// keeps the last cover for up to 2 s while the new one arrives (so the pill flips once), and History used to save
    /// that one. Every row then had the cover of the song played before it (your screenshot, 2026-11-16).
    func follow(_ item: NowPlaying?, now: Date = .now) {
        guard let item, let app = item.sourceBundleIdentifier, !item.title.isEmpty else { return }  // a gap isn't a new song
        if let playing, playing.app == app, playing.identity == item.identity {
            if playing.entry.cover == nil, let cover = item.artwork { self.playing?.entry.cover = Self.thumbnail(cover) }
            return
        }
        finish(now: now)
        playing = (app, item.identity, HistoryEntry(title: item.title, artist: item.artist, cover: item.artwork.flatMap(Self.thumbnail),
                                                    playedAt: now), now)
        // Its ID in its app, read while it's the one playing (only Music and Spotify have one).
        askingID?.cancel()
        guard let player = ScriptablePlayer(bundleID: item.bundleIdentifier) else { return }
        let identity = item.identity
        askingID = Task { [weak self, service] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let id = await service.currentSongID(in: player),
                  PlayHistoryRules.isValidSongID(id, for: player),
                  let self, self.playing?.identity == identity else { return }
            self.playing?.entry.songID = id
        }
    }

    /// The song that was playing joins its app's History, if it played long enough.
    private func finish(now: Date) {
        guard let playing, now.timeIntervalSince(playing.since) >= PlayHistoryRules.minimumPlay else { return }
        byApp[playing.app] = PlayHistoryRules.adding(playing.entry, to: byApp[playing.app] ?? [])
        file.save(byApp)
    }

    /// 96 px JPEG: enough for the 44 pt row on a Retina screen.
    private static func thumbnail(_ data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let side = 96
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}

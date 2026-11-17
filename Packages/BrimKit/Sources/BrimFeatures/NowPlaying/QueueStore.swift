import Observation
import SwiftUI
import BrimCore

/// The full-screen player's queue (2026-10-29): read from the app that's playing, its own way (`QueueService`), only
/// while the queue shows: as it opens, when the song changes, and every 15 s. A click plays a song now.
@Observable
public final class QueueStore {
    public private(set) var queue: PlayerQueue = .loading
    /// The row being started: it shows a spinner until the player moves.
    public private(set) var starting: String?

    @ObservationIgnored private let service: QueueService
    @ObservationIgnored private let nowPlaying: NowPlayingStore

    public init(service: QueueService, nowPlaying: NowPlayingStore) {
        self.service = service
        self.nowPlaying = nowPlaying
    }

    private var player: ScriptablePlayer? { ScriptablePlayer(bundleID: nowPlaying.item?.bundleIdentifier) }

    public func refresh() async {
        guard nowPlaying.item != nil else { queue = .empty; return }
        guard let player else { queue = .unavailable(app: nowPlaying.sourceName); return }
        queue = Self.withoutPlaying(await service.queue(of: player), playing: nowPlaying.item)
    }

    /// The playing song never shows as next (your screenshot, 2026-10-29): right after a song changes, the app can
    /// still report the one before as current for a moment, so its list started with the song now playing.
    static func withoutPlaying(_ queue: PlayerQueue, playing: NowPlaying?) -> PlayerQueue {
        guard case .items(let source, let items) = queue, let playing,
              let first = items.first, first.title == playing.title,
              first.artist == nil || playing.artist == nil || first.artist == playing.artist else { return queue }
        let rest = Array(items.dropFirst())
        return rest.isEmpty ? .empty : .items(source: source, rest)
    }

    /// Covers read from the app, kept while Brim runs (a playlist's 25 at most at a time).
    @ObservationIgnored private var covers: [String: NSImage] = [:]

    /// A queued song's cover from the app itself (Music), when the list didn't bring one.
    public func cover(for item: QueueItem) async -> NSImage? {
        if let cached = covers[item.id] { return cached }
        guard let player, let data = await service.cover(of: item, in: player), let image = NSImage(data: data) else { return nil }
        if covers.count > 200 { covers.removeAll() }
        covers[item.id] = image
        return image
    }

    public func play(_ item: QueueItem, position: Int) async {
        guard let player, starting == nil else { return }
        starting = item.id
        _ = await service.play(item, position: position, in: player)
        try? await Task.sleep(for: .milliseconds(700))  // let the player move on before asking again
        await refresh()
        starting = nil
    }
}

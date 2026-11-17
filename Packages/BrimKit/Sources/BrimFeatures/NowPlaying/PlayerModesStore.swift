import Foundation
import Observation
import BrimCore

/// Shuffle, repeat and ★ for the playing app, when it's Spotify or Music (PRD F2).
///
/// Read when the buttons appear (the island opening, the full-screen player) and after each change; never polled.
/// A click shows at once, then waits for the player to confirm (your fix round 2, item 9: measured 2026-09-30, Music
/// reports a change 0.3–1 s later, and reading back after 0.25 s showed the old value and flipped the button back).
@Observable
public final class PlayerModesStore {
    /// Nil hides the buttons: not Spotify or Music, the player isn't answering, or Automation was refused.
    public private(set) var modes: PlayerModes?
    public private(set) var player: ScriptablePlayer?
    /// Spotify or Music is showing but didn't answer Brim (Spotify 1.3.3 stopped answering, 2026-10-02): the buttons
    /// that need it stay, faded, and say why on hover. Cleared by its next answer.
    public private(set) var unreachable = false

    @ObservationIgnored private let service: any PlayerControlsService
    @ObservationIgnored private let nowPlaying: NowPlayingStore
    @ObservationIgnored private var reading: Task<Void, Never>?
    /// Reading back your latest change; a plain read waits for it, so it can't show a value the player hasn't caught up to.
    @ObservationIgnored private var confirming: Task<Void, Never>?
    /// Counts your clicks: only the latest one's reading decides what shows.
    @ObservationIgnored private var clicks = 0
    /// When to read back after a change, from the moment it's sent. The last one decides if it never matches.
    @ObservationIgnored private let confirmAt: [Duration]
    /// Each player's last answer: switching back to it (from a video, say) shows its buttons at once, then reads again.
    /// A Spotify Web API read takes ~0.2 s (measured 2026-10-02); without this the buttons popped in that late.
    @ObservationIgnored private var lastModes: [ScriptablePlayer: PlayerModes] = [:]

    public init(service: any PlayerControlsService, nowPlaying: NowPlayingStore,
                confirmAt: [Duration] = [.milliseconds(300), .milliseconds(600), .milliseconds(1200), .seconds(2)]) {
        self.service = service
        self.nowPlaying = nowPlaying
        self.confirmAt = confirmAt
    }

    /// Asks the playing app for its shuffle and repeat.
    public func refresh() {
        let player = ScriptablePlayer(bundleID: nowPlaying.item?.sourceBundleIdentifier)
        if player != self.player {
            if let old = self.player, let modes { lastModes[old] = modes }
            modes = player.flatMap { lastModes[$0] }
            unreachable = false
            confirming?.cancel()
            confirming = nil
        }
        self.player = player
        reading?.cancel()
        guard let player, confirming == nil else { return }
        let track = self.track
        reading = Task { [weak self, service] in
            let modes = await service.modes(of: player, track: track)
            guard !Task.isCancelled, let self, self.confirming == nil else { return }
            self.modes = modes
            self.unreachable = modes == nil
        }
    }

    public func toggleShuffle() {
        guard let player, var next = modes, next.canChange else { return }
        next.shuffle.toggle()
        let on = next.shuffle
        change(to: next, in: player) { [service, nowPlaying] in
            // While Music is the Now Playing app, also the way Control Center does it: Music may ignore the Apple
            // Event while playing (seen once, 2026-09-30). Both set a value (never a toggle), so sending both is safe.
            if player == .music, nowPlaying.playerReachedThroughNowPlaying == .music {
                await nowPlaying.setShuffleThroughNowPlaying(on)
            }
            _ = await service.setShuffle(on, in: player)
        }
    }

    /// ★ in Apple Music (C1), and Spotify's Liked Songs (0.18.3). Shows at once; the player confirms.
    public func toggleFavorite() {
        guard let player, var next = modes, let favorite = next.favorite else { return }
        next.favorite = !favorite
        let track = self.track
        change(to: next, in: player) { [service] in _ = await service.setFavorite(!favorite, in: player, track: track) }
    }

    /// Spotify's song for ★, as its app announced it: Spotify's Web API can still report the song before for a moment.
    private var track: String? { player == .spotify ? nowPlaying.spotifyTrack : nil }

    public func cycleRepeat() {
        guard let player, var next = modes, next.canChange else { return }
        if next.repeatOnMayBeOne, next.repeatMode != .off {
            // Spotify's menu: from "on" a press goes All → One or One → off, and its one checkmark can't say which it
            // was. No guess: the press goes out and the button shows what Spotify reports (~0.3–1 s later).
            report(after: { [service] in _ = await service.setRepeat(.off, in: player) }, in: player)
            return
        }
        next.repeatMode = next.repeatMode.next(hasOne: player == .music || next.repeatHasOne)
        let mode = next.repeatMode
        change(to: next, in: player) { [service, nowPlaying] in
            if player == .music, nowPlaying.playerReachedThroughNowPlaying == .music {
                await nowPlaying.setRepeatThroughNowPlaying(mode)
            }
            _ = await service.setRepeat(mode, in: player)
        }
    }

    /// Sends a change whose result Brim can't predict, then shows what the player reports, read after it has had time
    /// to apply it (Spotify's menu updates ~0.3–1 s later). The latest click decides.
    private func report(after send: @escaping @MainActor () async -> Void, in player: ScriptablePlayer) {
        clicks += 1
        let click = clicks
        let track = self.track
        reading?.cancel()
        confirming?.cancel()
        confirming = Task { [weak self, service] in
            await send()
            let sent = ContinuousClock.now
            for moment in [Duration.milliseconds(600), .milliseconds(1200), .seconds(2)] {
                try? await Task.sleep(until: sent + moment)
                guard !Task.isCancelled else { return }
                let answer = await service.modes(of: player, track: track)
                guard !Task.isCancelled, let self, self.clicks == click else { return }
                if let answer { self.modes = answer }
            }
            if let self, self.clicks == click { self.confirming = nil }
        }
    }

    /// Shows `wanted` at once, sends it, then reads the player back until it reports all of it. If it never does
    /// (Spotify locks shuffle in radio; a player ignores it), what the player really has shows after the last read.
    private func change(to wanted: PlayerModes, in player: ScriptablePlayer, send: @escaping @MainActor () async -> Void) {
        modes = wanted
        clicks += 1
        let click = clicks
        let track = self.track
        reading?.cancel()
        confirming?.cancel()
        confirming = Task { [weak self, service, confirmAt] in
            await send()  // an earlier click's send still completes: only its reading stops
            let sent = ContinuousClock.now
            var answer: PlayerModes?
            for moment in confirmAt {
                try? await Task.sleep(until: sent + moment)
                guard !Task.isCancelled else { return }
                answer = await service.modes(of: player, track: track)
                guard !Task.isCancelled else { return }
                if let answer, answer.matches(wanted) { break }
            }
            guard let self, self.clicks == click else { return }
            self.confirming = nil
            guard let answer else {
                // It never answered: say so, instead of showing a change that may not have happened.
                self.modes = nil
                self.unreachable = true
                return
            }
            self.modes = answer
            self.unreachable = false
            if !answer.matches(wanted) {
                Log.nowPlaying.notice("\(player.rawValue, privacy: .public) didn't take a shuffle/repeat/favorite change within 2 s")
            }
        }
    }
}

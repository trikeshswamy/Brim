import Foundation
import Observation
import BrimCore

/// The playing app's own volume (Music's or Spotify's, 0–100), apart from the Mac's (your find, 2026-11-17: Apple
/// Music's full-screen slider turns only Music down; YouTube and everything else keep the Mac's volume). The full-screen
/// slider uses it while Music or Spotify plays and answers; otherwise the Mac's volume, as before.
@Observable
public final class AppVolumeStore {
    /// 0…1; nil when the playing app isn't Music or Spotify, or didn't answer.
    public private(set) var level: Double?
    public private(set) var player: ScriptablePlayer?

    @ObservationIgnored private let service: any PlayerControlsService
    @ObservationIgnored private let nowPlaying: NowPlayingStore
    @ObservationIgnored private var reading: Task<Void, Never>?
    /// A drag sends many levels: only the latest waits, one Apple Event at a time.
    @ObservationIgnored private var waiting: Int?
    @ObservationIgnored private var sending: Task<Void, Never>?
    /// The level you chose for each app (⌃ + volume or the slider), and the app's own level before Brim first changed
    /// it. Your report, 2026-11-17: Music came back to full volume after you paused and played it again. On a resume
    /// Brim looks: back at the old level → yours is set again; anything else → you changed it in the app, so it's yours.
    @ObservationIgnored private var kept: [ScriptablePlayer: (wanted: Int, before: Int)] = [:]
    @ObservationIgnored private var wasPlaying: [ScriptablePlayer: Bool] = [:]
    @ObservationIgnored private var checking: Task<Void, Never>?
    /// How long after a resume Brim looks (Music settles its volume a moment after it starts).
    @ObservationIgnored var resumeCheckDelay: Duration = .seconds(1)

    public init(service: any PlayerControlsService, nowPlaying: NowPlayingStore) {
        self.service = service
        self.nowPlaying = nowPlaying
    }

    /// Asks the playing app (the full-screen player opening, the song or the app changing).
    public func refresh() {
        let player = ScriptablePlayer(bundleID: nowPlaying.item?.sourceBundleIdentifier)
        if player != self.player { level = nil }
        self.player = player
        reading?.cancel()
        guard let player, sending == nil else { return }
        reading = Task { [weak self, service] in
            let answer = await service.appVolume(in: player)
            guard !Task.isCancelled, let self, self.player == player, self.sending == nil else { return }
            self.level = answer.map { Double($0) / 100 }
        }
    }

    /// Follows play and pause, to keep your level across a resume.
    public func start() {
        observe { [weak self] in
            guard let self, let item = self.nowPlaying.item,
                  let player = ScriptablePlayer(bundleID: item.sourceBundleIdentifier) else { return }
            let playing = item.isPlaying
            let was = self.wasPlaying[player] ?? playing
            self.wasPlaying[player] = playing
            if playing, !was { self.resumed(player) }
        }
    }

    func resumed(_ player: ScriptablePlayer) {
        guard let keep = kept[player] else { return }
        checking?.cancel()
        checking = Task { [weak self, service, resumeCheckDelay] in
            try? await Task.sleep(for: resumeCheckDelay)
            guard !Task.isCancelled, let now = await service.appVolume(in: player), let self else { return }
            if abs(now - keep.wanted) <= 1 { return }
            if abs(now - keep.before) <= 1 {
                Log.app.notice("\(player.rawValue, privacy: .public) put its own volume back to \(now, privacy: .public) on resume; set to your \(keep.wanted, privacy: .public) again")
                _ = await service.setAppVolume(keep.wanted, in: player)
                if self.player == player { self.level = Double(keep.wanted) / 100 }
            } else {
                Log.app.notice("\(player.rawValue, privacy: .public) volume is \(now, privacy: .public) on resume (changed in the app): kept")
                self.kept[player] = nil
            }
        }
    }

    /// ⌃ + a volume key (your pick, 2026-11-17): one step of the music app's own volume. Answers at once whether
    /// Music or Spotify is the playing app (the key is then Brim's); the level is read, stepped and shown after.
    /// Held down, the steps go from the level just set, without asking the app again each time.
    @ObservationIgnored public var onStep: ((Double, ScriptablePlayer) -> Void)?
    @ObservationIgnored private var lastStep = Date.distantPast

    public func step(up: Bool, fine: Bool) -> Bool {
        // Always your music: Music or Spotify on screen, or playing behind a video or a meeting.
        guard let player = nowPlaying.musicApp else { return false }
        if player != self.player { self.player = player; level = nil }
        let recent = Date.now.timeIntervalSince(lastStep) < 1.5
        lastStep = .now
        if recent, let level {
            let next = LevelStep.next(from: level, up: up, fine: fine)
            set(next)
            onStep?(next, player)
            return true
        }
        Task { [weak self, service] in
            guard let current = await service.appVolume(in: player), let self, self.player == player else {
                Log.app.notice("Music volume key: \(player.rawValue, privacy: .public) didn't answer")
                return
            }
            self.level = Double(current) / 100
            let next = LevelStep.next(from: Double(current) / 100, up: up, fine: fine)
            self.set(next)
            self.onStep?(next, player)
        }
        return true
    }

    /// Shows at once; the app gets the latest level, one at a time.
    public func set(_ level: Double) {
        guard let player, let old = self.level else { return }
        let clamped = min(max(level, 0), 1)
        self.level = clamped
        waiting = Int((clamped * 100).rounded())
        kept[player] = (wanted: Int((clamped * 100).rounded()), before: kept[player]?.before ?? Int((old * 100).rounded()))
        guard sending == nil else { return }
        sending = Task { [weak self, service] in
            while let self, let next = self.waiting {
                self.waiting = nil
                _ = await service.setAppVolume(next, in: player)
            }
            self?.sending = nil
        }
    }
}

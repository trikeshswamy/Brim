import Foundation
import Observation
import BrimCore

/// Synced lyrics for the song that's playing (PRD F5).
///
/// - Looks lyrics up once per song, as soon as the song starts, so they're ready when you open the island.
/// - Keeps `currentIndex` in time with the song, but only while a view shows lyrics: one scheduled wake-up
///   at the next line, never a repeating timer. Pausing stops the wake-ups; seeking re-syncs at once.
/// - Keeps the song's lyrics through the noise players make when you shuffle or switch outputs: the same song
///   announced a little differently (`LyricsQuery.isSameSong`), or Now Playing going blank for a moment.
@Observable
public final class LyricsStore {
    public enum Status: Equatable, Sendable {
        /// Settings → Lyrics is off.
        case off
        /// Nothing playing, or not a song we look up (a podcast, a long video, missing title or artist).
        case none
        case loading
        /// `lyrics` holds synced lines, plain words, or "instrumental".
        case ready
        case notFound
        case offline
        case rateLimited
        case failed
    }

    /// "Try Another Version" for this song (your pick, 2026-09-30).
    public enum VersionSearch: Equatable, Sendable {
        /// Not asked yet for this song.
        case idle
        case searching
        /// Showing version `current` (from 0) of the `count` distinct ones LRCLIB has at this length.
        case found(current: Int, count: Int)
        /// Offline, rate-limited, or LRCLIB failed; asking again is fine.
        case unavailable
    }

    public private(set) var status: Status = .none
    /// The lyrics as shown: LRCLIB's timing plus your timing fix for this song.
    public private(set) var lyrics: Lyrics?
    /// The line playing now. Kept current only while a view is showing lyrics.
    public private(set) var currentIndex: Int?
    /// Your timing fix for this song in seconds (negative = lines earlier). Already applied to `lyrics`.
    public private(set) var timingOffset: TimeInterval = 0
    public private(set) var versionSearch: VersionSearch = .idle
    /// Where "Fix Lyrics Timing…" was opened, while its bar shows; nil when it doesn't.
    public private(set) var syncing: SyncPlace?

    public enum SyncPlace: Sendable { case island, fullScreen }

    /// About how long after a line starts you click it (a person's reaction to hearing it).
    static let clickDelay: TimeInterval = 0.2
    /// The word sweep's timing for the current line (nil: no line with words). Changes only when the line
    /// changes, the song pauses or plays, or jumps; Core Animation plays it (see `SweepLine`).
    public private(set) var sweepClock: SweepClock?
    private var nextWord: TimeInterval?

    /// The most a fix can move lines. Bigger errors mean a different cut of the song: try another version.
    static let maxOffset: TimeInterval = 5

    /// Debug verification: called at each line switch with the line's time and the song position at that moment.
    @ObservationIgnored public var onLineSwitch: ((_ lineTime: TimeInterval, _ position: TimeInterval) -> Void)?

    @ObservationIgnored private let service: any LyricsService
    @ObservationIgnored private let nowPlaying: NowPlayingStore
    /// The latest Now Playing update this store was given (position, play state, rate).
    @ObservationIgnored private var item: NowPlaying?
    @ObservationIgnored private var query: LyricsQuery?
    /// The lyrics as LRCLIB (or your chosen version) timed them, before your timing fix.
    @ObservationIgnored private var timed: Lyrics?
    /// Distinct versions, once asked for; `timed` is one of them.
    @ObservationIgnored private var versions: [LyricsVersion] = []
    @ObservationIgnored private var lookup: Task<Void, Never>?
    @ObservationIgnored private var versionLookup: Task<Void, Never>?
    /// Saves run one after another, so two quick nudges can't be stored in reverse order.
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private var nextLine: Task<Void, Never>?
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var enabled = true
    @ObservationIgnored private var started = false
    /// How long the lyrics wait when Now Playing goes blank mid-song before clearing. If the same song is back
    /// within it (players drop out for a moment when you shuffle or switch outputs), nothing resets.
    @ObservationIgnored private let dropoutGrace: Duration
    @ObservationIgnored private var dropout: Task<Void, Never>?
    @ObservationIgnored private var dropoutStarted: Date?
    /// The last differences logged for this song, so a player that always announces it differently logs once.
    @ObservationIgnored private var loggedDifferences: [String] = []

    public init(service: any LyricsService, nowPlaying: NowPlayingStore, dropoutGrace: Duration = .seconds(3)) {
        self.service = service
        self.nowPlaying = nowPlaying
        self.dropoutGrace = dropoutGrace
    }

    /// Follows Now Playing from now on.
    public func start() {
        guard !started else { return }
        started = true
        observe { [weak self] in
            guard let self else { return }
            self.follow(self.nowPlaying.item)
        }
    }

    /// Settings → Lyrics.
    public func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        query = nil
        if on {
            follow(item)
        } else {
            clear(.off)
        }
    }

    /// Views that show lyrics call these, so line tracking runs only while lyrics are on screen.
    public func beginDisplay() {
        viewers += 1
        resync()
    }

    public func endDisplay() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { nextLine?.cancel() }
    }

    /// Internal so tests can drive it directly.
    func follow(_ item: NowPlaying?) {
        self.item = item
        guard enabled else { return }
        if let query, let item, query.isSameSong(as: item) {
            // Still this song (the lookup keeps the details it started with, so its cache and fixes stay put).
            if let blank = endDropout() {
                Log.nowPlaying.notice("Lyrics kept: the song came back after \(Int(blank * 1000), privacy: .public) ms blank")
            }
            noteDifferences(from: item, against: query)
        } else if query != nil, item == nil {
            beginDropout()
        } else {
            endDropout()
            let next = item.flatMap(LyricsQuery.init)
            if next != query {
                query = next
                clear(next == nil ? .none : .loading)
                if let next { look(up: next) }
            }
        }
        resync()  // play, pause, and seek all arrive as Now Playing updates
    }

    /// Now Playing went blank mid-song: keep the lyrics for `dropoutGrace`, then clear them.
    private func beginDropout() {
        guard dropout == nil else { return }
        dropoutStarted = .now
        dropout = Task { [weak self, dropoutGrace] in
            try? await Task.sleep(for: dropoutGrace)
            guard !Task.isCancelled, let self else { return }
            self.dropout = nil
            Log.nowPlaying.notice("Lyrics cleared: Now Playing stayed blank")
            self.query = nil
            self.clear(.none)
        }
    }

    /// Stops waiting; returns how long Now Playing was blank, if it was.
    @discardableResult
    private func endDropout() -> TimeInterval? {
        guard let dropout else { return nil }
        dropout.cancel()
        self.dropout = nil
        return dropoutStarted.map { Date.now.timeIntervalSince($0) }
    }

    /// Logs which details a player announced differently for the same song (names only), once per change.
    private func noteDifferences(from item: NowPlaying, against query: LyricsQuery) {
        let differences = query.differences(from: item)
        guard differences != loggedDifferences else { return }
        loggedDifferences = differences
        guard !differences.isEmpty else { return }
        Log.nowPlaying.notice("Lyrics kept: same song announced with a different \(differences.joined(separator: ", "), privacy: .public)")
    }

    private func look(up query: LyricsQuery) {
        lookup = Task { [weak self, service] in
            let result = await service.lyrics(for: query)
            let offset = await service.offset(for: query)
            guard !Task.isCancelled else { return }
            self?.apply(result, offset: offset, for: query)
        }
    }

    private func apply(_ result: LyricsResult, offset: TimeInterval, for query: LyricsQuery) {
        guard query == self.query else { return }  // the song changed while we were looking
        switch result {
        case .found(let found):
            timed = found
            timingOffset = offset
            lyrics = found.shifted(by: offset)
            status = .ready
        case .notFound: status = .notFound
        case .offline: status = .offline
        case .rateLimited: status = .rateLimited
        case .failed(let reason):
            status = .failed
            Log.nowPlaying.error("Lyrics lookup failed: \(reason, privacy: .public)")
        }
        // Couldn't ask (LRCLIB busy, offline, slowed down): ask once more in 30 s if it's still this song, instead of
        // staying without lyrics until the next one (your trace, 2026-10-30).
        if case .found = result {} else if case .notFound = result {} else { askAgainLater(for: query) }
        resync()
    }

    @ObservationIgnored private var askAgain: Task<Void, Never>?
    @ObservationIgnored private var askedAgain: LyricsQuery?

    private func askAgainLater(for query: LyricsQuery) {
        guard askedAgain != query else { return }  // once per song
        askedAgain = query
        askAgain?.cancel()
        askAgain = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.query == query, self.status != .ready else { return }
            self.status = .loading
            self.look(up: query)
        }
    }

    private func clear(_ newStatus: Status) {
        endDropout()
        loggedDifferences = []
        lookup?.cancel()
        versionLookup?.cancel()
        nextLine?.cancel()
        timed = nil
        lyrics = nil
        currentIndex = nil
        timingOffset = 0
        versions = []
        versionSearch = .idle
        sweepClock = nil
        syncing = nil  // a new song: its own timing
        status = newStatus
    }

    // MARK: - Your timing fixes (right-click menu)

    /// Timed lyrics are loaded, so the timing menu applies.
    public var canAdjustTiming: Bool {
        guard status == .ready, case .synced? = lyrics else { return false }
        return true
    }

    /// "Fix Lyrics Timing…" (your pick, 2026-11-16): a bar under the lyrics while they keep playing, instead of a menu
    /// item per 0.25 s that you clicked blind (macOS stops Brim while a menu is open, so the lines couldn't move under
    /// it; your −2.00 s took 8 two-finger clicks).
    public func startSync(in place: SyncPlace) {
        guard canAdjustTiming else { return }
        Usage.note("lyrics.sync")
        syncClicks = []
        syncing = place
    }

    /// The fix each click asked for since the bar opened. The middle one is used, so one early or late click doesn't
    /// throw the rest off (your report, 2026-11-17: each click replaced the last, so one had to be timed exactly).
    private var syncClicks: [TimeInterval] = []
    /// A click this far from the others is you correcting a wrong line, not a slow click: it starts over from there.
    static let syncRestart: TimeInterval = 1.5

    /// Done, or the place showing the bar went away (`place`: only if the bar is that one's).
    public func endSync(in place: SyncPlace? = nil) {
        guard let syncing, place == nil || place == syncing else { return }
        self.syncing = nil
    }

    /// You clicked the line shown at `time` as it was sung: every line moves so that one starts now (less the moment
    /// it took you to click). Remembered for this song, like the steps.
    public func syncLine(shownAt time: TimeInterval) {
        guard syncing != nil, let position = item?.position(at: .now) else { return }
        Usage.note("lyrics.sync.line")
        let asked = timingOffset + position - Self.clickDelay - time
        if let middle = Self.middle(syncClicks), abs(asked - middle) > Self.syncRestart { syncClicks = [] }
        syncClicks.append(asked)
        setTimingOffset(Self.middle(syncClicks) ?? asked)
    }

    /// The median: the middle click, or the average of the two middle ones.
    static func middle(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), half = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[half - 1] + sorted[half]) / 2 : sorted[half]
    }

    /// Moves every line earlier (negative) or later by `seconds`, remembered for this song.
    public func nudge(by seconds: TimeInterval) {
        Usage.note("lyrics.nudge")
        syncClicks = syncClicks.map { $0 + seconds }  // the clicks move with it, so the next click doesn't undo it
        setTimingOffset(timingOffset + seconds)
    }

    public func resetTiming() {
        setTimingOffset(0)
    }

    private func setTimingOffset(_ value: TimeInterval) {
        guard let query, let timed, canAdjustTiming else { return }
        let offset = min(max((value * 100).rounded() / 100, -Self.maxOffset), Self.maxOffset)
        guard offset != timingOffset else { return }
        timingOffset = offset
        lyrics = timed.shifted(by: offset)
        resync()
        save { [service] in await service.setOffset(offset, for: query) }
    }

    /// Asks LRCLIB for other timed versions of this song (only on your click). They appear as a list in the
    /// menu, each labelled by how it differs from the one in use; nothing changes until you pick one.
    public func findVersions() {
        guard let query, canAdjustTiming else { return }
        Usage.note("lyrics.versions")
        switch versionSearch {
        case .searching, .found:
            return
        case .idle, .unavailable:
            versionSearch = .searching
            versionLookup = Task { [weak self, service] in
                let result = await service.versions(for: query)
                guard !Task.isCancelled else { return }
                self?.receive(result, for: query)
            }
        }
    }

    private func receive(_ result: LyricsVersionsResult, for query: LyricsQuery) {
        guard query == self.query else { return }
        guard case .found(let found) = result, !found.isEmpty else {
            versionSearch = .unavailable
            return
        }
        versions = found
        versionSearch = .found(current: 0, count: found.count)  // found[0] is the version in use
    }

    /// Uses version `index` from the list, remembered for this song. Your timing fix goes back to 0:
    /// it was made for the other version.
    public func useVersion(_ index: Int) {
        guard let query, case .found(let current, _) = versionSearch, index != current,
              versions.indices.contains(index) else { return }
        switchVersion(to: index, for: query)
    }

    /// How version `index` compares with the one in use: its shift (negative: earlier) and how many of its
    /// lines are the same words.
    public func versionComparison(_ index: Int) -> LRCLIBVersions.Comparison? {
        guard case .found(let current, _) = versionSearch, versions.indices.contains(index),
              versions.indices.contains(current) else { return nil }
        if index == current { return LRCLIBVersions.Comparison(shift: 0, coverage: 1) }
        return LRCLIBVersions.compare(versions[index].lines, versions[current].lines)
    }

    private func switchVersion(to index: Int, for query: LyricsQuery) {
        let version = versions[index]
        timed = .synced(version.lines)
        timingOffset = 0
        lyrics = timed
        versionSearch = .found(current: index, count: versions.count)
        resync()
        save { [service] in await service.use(version, for: query) }
    }

    private func save(_ work: @escaping @Sendable () async -> Void) {
        saving = Task { [previous = saving] in
            await previous?.value
            await work()
        }
    }

    // MARK: - Word sweep

    /// Sets `sweepClock` for the current line, only when something changed (another line, play/pause, or a
    /// jump of more than 2%), so the views that play it update a few times per line, not every frame.
    /// With real word timing the pace changes at each word: `nextWord` is when, for resync's wake-up.
    private func updateSweepClock(position: TimeInterval, item: NowPlaying) {
        nextWord = nil
        guard let index = currentIndex, case .synced(let lines)? = lyrics, !lines[index].text.isEmpty else {
            if sweepClock != nil { sweepClock = nil }
            return
        }
        let line = lines[index]
        let nextStart = lines[(index + 1)...].first?.time ?? (item.duration ?? line.time + 5)
        // Word by word only with real word timing (your pick, 2026-11-17, like Apple Music): a line timed only as a
        // whole lights up at once, on time. Before, it swept at a guessed 5 letters a second, which ran ahead of or
        // behind the singer on most lines (0 of your 57 songs have word timing on LRCLIB).
        guard !line.marks.isEmpty else {
            if sweepClock != nil { sweepClock = nil }
            return
        }
        let timed = LyricSweep.timed(marks: line.marks, letters: line.text.count, start: line.time,
                                     nextStart: nextStart, position: position)
        let (progress, duration) = (timed.progress, timed.duration)
        nextWord = timed.until
        let now = Date()
        let clock = SweepClock(line: index, progress: progress, anchor: now, duration: duration, playing: item.isPlaying)
        if let current = sweepClock, current.line == clock.line, current.playing == clock.playing,
           abs(current.duration - clock.duration) < 0.01 * clock.duration,
           abs(current.progress(at: now) - clock.progress) < 0.02 { return }
        sweepClock = clock
    }

    /// Works out the current line and schedules one wake-up for the next.
    private func resync() {
        nextLine?.cancel()
        guard viewers > 0, let lyrics, let item, let position = item.position(at: .now) else { return }
        let index = lyrics.currentLineIndex(at: position)
        if index != currentIndex {
            currentIndex = index
            if let index, case .synced(let lines) = lyrics { onLineSwitch?(lines[index].time, position) }
        }
        updateSweepClock(position: position, item: item)
        let following = [lyrics.nextLineTime(after: position), nextWord].compactMap { $0 }.min()
        guard item.isPlaying, let next = following else { return }
        let rate = max(item.playbackRate ?? 1, 0.1)
        let delay = (next - position) / rate + 0.005  // a hair late rather than early, so one wake-up is enough
        nextLine = Task { [weak self] in
            // An explicit tolerance: without one, macOS may batch this wake-up with others for power,
            // and the trace measured lines landing up to 273 ms late (target ±150 ms).
            try? await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(5))
            guard !Task.isCancelled else { return }
            self?.resync()
        }
    }
}

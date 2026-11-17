import AppKit
import BrimCore

/// Now Playing through the bundled helper: one `stream` process plus one-shot commands.
///
/// Reliability rules (PRD F3):
/// - if the stream dies, restart it after 1, 2, 4, 8 … up to 60 s;
/// - after 5 failures in a row, report "unavailable" (keep retrying in the background);
/// - a run that lasted over 30 s resets the failure count.
public final class LiveNowPlayingService: NowPlayingService {
    public let events: AsyncStream<NowPlayingEvent>
    private let continuation: AsyncStream<NowPlayingEvent>.Continuation
    private let helper: AdapterHelper?

    private var process: Process?
    /// Changes on every launch, so late events from an old process are ignored.
    private var generation = 0
    private var wantsStream = false
    private var restartingOnPurpose = false
    private var startedAt = Date.distantPast
    private var restarts = 0
    private var consecutiveFailures = 0
    private var retry: Task<Void, Never>?
    private var safariPoll: Task<Void, Never>?
    private var systemItem: NowPlaying?
    private var safariItem: NowPlaying?
    private var publishedItem: NowPlaying?

    public init(bundle: Bundle = .main) {
        (events, continuation) = AsyncStream.makeStream(of: NowPlayingEvent.self)
        helper = AdapterHelper(bundle: bundle)
    }

    public func start() {
        guard let helper else {
            continuation.yield(.availability(.unavailable(reason: "The Now Playing helper is missing from Brim.app.")))
            Log.helper.fault("Helper files not found in the app bundle")
            return
        }
        guard !wantsStream else { return }
        wantsStream = true
        helper.killOrphans()
        startSafariFallback()
        launch()
    }

    /// Stops the stream and waits briefly for it to exit (called on quit).
    public func stop() {
        wantsStream = false
        retry?.cancel()
        safariPoll?.cancel()
        safariPoll = nil
        safariItem = nil
        systemItem = nil
        publishedItem = nil
        guard let process, process.isRunning else { return }
        process.terminate()  // SIGTERM: the helper stops its run loop and exits with status 0
        // At most a second: a helper stuck in MediaRemote (after sleep) used to keep Quit Brim waiting forever (code
        // review, 2026-11-17). Then SIGKILL; the next launch's `killOrphans` clears anything left.
        let deadline = Date.now.addingTimeInterval(1)
        while process.isRunning && Date.now < deadline { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        self.process = nil
    }

    /// Your Retry (the Music tab, after the helper kept stopping): try now instead of waiting out the backoff (up to
    /// 60 s), and count failures afresh. Cancels the pending try, so two helpers never run at once.
    public func retryNow() {
        guard wantsStream else { return }
        retry?.cancel()
        consecutiveFailures = 0
        if let process, process.isRunning { return }  // already back
        launch()
    }

    /// Restart on purpose, e.g. after wake, when MediaRemote's state may be stale. Doesn't count as a failure.
    public func restart() {
        guard wantsStream else { return }
        guard let process, process.isRunning else { return launch() }
        restartingOnPurpose = true
        process.terminate()  // the exit event relaunches it
    }

    public func perform(_ command: MediaCommand) async {
        if safariIsSelected {
            // Off the main thread, like `read()`: finding the button can walk thousands of Accessibility nodes in
            // another process (3–7 s on a big page), and the island and the media keys froze meanwhile (code review,
            // 2026-11-17).
            if await Task.detached(priority: .userInitiated, operation: { SafariAccessibilityMedia.perform(command) }).value {
                return
            }
            // Safari's AX tree can temporarily hide a web player's button. Give the same
            // command one MediaRemote attempt before reporting failure; this is a fallback,
            // not a retry loop.
            Log.helper.debug("Safari AX did not accept media command; trying MediaRemote")
        }
        guard let helper else { return }
        let status = await helper.run(["send", String(command.rawValue)])
        if status != 0 { Log.helper.error("send \(command.rawValue) exited with \(status)") }
    }

    public func seek(to position: TimeInterval) async {
        if safariIsSelected {
            let duration = safariItem?.duration
            if await Task.detached(priority: .userInitiated, operation: {
                SafariAccessibilityMedia.seek(to: position, duration: duration)
            }).value { return }
            // AX sliders are not exposed consistently by web players. MediaRemote can still
            // seek in browsers that publish a Now Playing session, so use it as one fallback.
            Log.helper.debug("Safari AX did not accept seek; trying MediaRemote")
        }
        guard let helper else { return }
        let micros = Int64((max(0, position) * 1_000_000).rounded())
        let status = await helper.run(["seek", String(micros)])
        if status != 0 { Log.helper.error("seek exited with \(status)") }
    }

    /// The helper's `shuffle <mode>`: 1 off, 3 songs (MediaRemote's shuffle modes; 2 would be albums).
    public func setShuffle(_ on: Bool) async {
        guard let helper else { return }
        let status = await helper.run(["shuffle", on ? "3" : "1"])
        if status != 0 { Log.helper.error("shuffle exited with \(status)") }
    }

    /// The helper's `repeat <mode>`: 1 off, 2 the song, 3 the playlist or album.
    public func setRepeat(_ mode: RepeatMode) async {
        guard let helper else { return }
        let value = switch mode {
        case .off: "1"
        case .one: "2"
        case .all: "3"
        }
        let status = await helper.run(["repeat", value])
        if status != 0 { Log.helper.error("repeat exited with \(status)") }
    }

    // MARK: - Stream lifecycle

    private func launch() {
        guard let helper, wantsStream else { return }
        generation += 1
        let thisGeneration = generation
        let continuation = self.continuation
        continuation.yield(.availability(.starting))
        do {
            process = try helper.startStream { [weak self] event in
                switch event {
                case .update(.item(let item)):
                    Task { @MainActor [weak self] in
                        self?.systemItem = item
                        self?.publishSelectedItem()
                    }
                case .update(.nothingPlaying):
                    Task { @MainActor [weak self] in
                        self?.systemItem = nil
                        self?.publishSelectedItem()
                    }
                case .update(.ignored):
                    break
                case .started(let pid):
                    Task { @MainActor in self?.didStart(pid: pid, generation: thisGeneration) }
                case .exited(let status):
                    Task { @MainActor in self?.didExit(status: status, generation: thisGeneration) }
                }
            }
        } catch {
            Log.helper.error("Couldn't start the helper: \(error.localizedDescription, privacy: .public)")
            didExit(status: -1, generation: thisGeneration)
        }
    }

    private func didStart(pid: Int32, generation: Int) {
        guard generation == self.generation else { return }
        startedAt = .now
        Log.helper.notice("Helper stream started, pid \(pid)")
        continuation.yield(.helper(HelperStatus(processID: pid, restarts: restarts)))
    }

    private func didExit(status: Int32, generation: Int) {
        guard generation == self.generation else { return }  // an old process; already replaced
        process = nil
        guard wantsStream else { return }                     // we stopped it on purpose (quit)

        if restartingOnPurpose {
            restartingOnPurpose = false
            Log.helper.notice("Helper restarted on purpose")
            return launch()
        }

        let ranFor = Date.now.timeIntervalSince(startedAt)
        consecutiveFailures = ranFor > 30 ? 1 : consecutiveFailures + 1
        restarts += 1
        let delay = min(60, pow(2, Double(consecutiveFailures - 1)))  // 1, 2, 4, 8, 16, 32, 60 s
        Log.helper.error("Helper exited with status \(status) after \(ranFor, format: .fixed(precision: 1)) s; restart #\(self.restarts) in \(delay, format: .fixed(precision: 0)) s")

        continuation.yield(.helper(HelperStatus(processID: nil, restarts: restarts)))
        if consecutiveFailures >= 5 {
            continuation.yield(.availability(.unavailable(reason: "The Now Playing helper keeps stopping. Brim will keep retrying.")))
        }
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.launch()
        }
    }

    private func startSafariFallback() {
        safariPoll?.cancel()
        safariPoll = Task { [weak self] in
            var lastHeard: Date?
            while !Task.isCancelled {
                guard !Task.isCancelled, let self else { return }
                // Two cheap questions first: is Safari open, and is a WebKit page playing sound? Only then look at
                // Safari's windows (SafariFallbackRules: a full look at a large page cost 3–7 s, every second).
                let now = Date()
                let safariRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty
                let sound = safariRunning && WebAudioActivity.webKitIsPlaying()
                if sound { lastHeard = now }
                if self.systemItem?.isPlaying == true {
                    self.safariItem = nil
                } else if SafariFallbackRules.shouldLook(safariRunning: safariRunning, webAudioPlaying: sound,
                                                         lastHeard: lastHeard, now: now) {
                    let snapshot = await Task.detached(priority: .utility) { SafariAccessibilityMedia.read() }.value
                    guard !Task.isCancelled else { return }
                    self.safariItem = snapshot?.nowPlaying
                } else {
                    self.safariItem = nil
                }
                self.publishSelectedItem()
                try? await Task.sleep(for: .seconds(SafariFallbackRules.interval(webAudioPlaying: sound)))
            }
        }
    }

    private var safariIsSelected: Bool {
        systemItem?.isPlaying != true && safariItem != nil
    }

    /// MediaRemote wins while it reports a playing item. Safari fills the gap when the system route is empty or paused.
    private func publishSelectedItem() {
        let selected: NowPlaying?
        if systemItem?.isPlaying == true {
            selected = systemItem
        } else if let safariItem {
            selected = safariItem
        } else {
            selected = systemItem
        }
        guard selected != publishedItem else { return }
        publishedItem = selected
        continuation.yield(.item(selected))
    }
}

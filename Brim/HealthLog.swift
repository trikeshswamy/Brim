import AppKit
import Darwin
import BrimCore
import BrimFeatures
import BrimSystem

/// Brim's daily health log (your pick, 2026-09-30): one line every 10 minutes in
/// `~/Library/Application Support/Brim/health.jsonl`, so problems that only appear over hours (memory creeping, a
/// stuck helper, sleep/wake trouble, a crash) show up while features are small and easy to trace. It lived in
/// `~/Library/Logs/Brim/` until 0.18.2: something that empties log folders removed it twice (2026-10-04 and -05).
///
/// - Numbers only: no song titles, names or anything you typed. Nothing leaves your Mac.
/// - For the 7-day run (your pick, 2026-10-01): `use`, counts of what you did since the last line (island opens by
///   how, tabs, timers, lyrics, media buttons, swipes, glances shown or quieted). See `Usage`.
/// - A "launch" line without a "quit" line before it means Brim crashed or was killed.
/// - One wake-up every 10 minutes (with 30 s of slack for macOS to batch it): the one timer Brim keeps,
///   because long-run health can't be measured without looking now and then.
@MainActor
final class HealthLog {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Brim/health.jsonl")
    /// Where it was until 0.18.2; moved over once, at the first launch that finds it there.
    private static let oldURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Brim/health.jsonl")
    private static var interval: Duration {
        #if DEBUG
        // Debug check: `--health-interval 5` writes a line every 5 s instead of every 10 minutes.
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--health-interval"), flag + 1 < args.count, let seconds = Int(args[flag + 1]) {
            return .seconds(seconds)
        }
        #endif
        return .seconds(600)
    }
    private static let sizeLimit = 1_000_000  // about a month of lines; older half dropped at launch

    private let environment: AppEnvironment
    private let launched = Date()
    private var ticker: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var last: ProcessSample?
    private var sleeps = 0
    private var systemWakes = 0
    private var screenChanges = 0

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func start() {
        moveFromLogsFolder()
        trim()
        last = ProcessSample.now()
        write(["event": "launch", "version": Self.version, "memMB": last.map { Self.megabytes($0.footprint) } ?? NSDecimalNumber.zero])
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeps += 1 }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemWakes += 1
                self?.write(["event": "wake"])
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenChanges += 1 }
        })
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval, tolerance: .seconds(30))
                guard !Task.isCancelled else { return }
                await self?.writeSample()
            }
        }
    }

    /// A one-off line, e.g. headphones connecting (P-4), so a problem can be traced to its moment.
    func event(_ name: String, _ fields: [String: Any] = [:]) {
        var entry = fields
        entry["event"] = name
        write(entry)
    }

    /// Called as Brim quits normally.
    func stop() {
        ticker?.cancel()
        var entry: [String: Any] = ["event": "quit", "up": Int(Date().timeIntervalSince(launched))]
        let use = Usage.take()
        if !use.isEmpty { entry["use"] = use }
        write(entry)
    }

    private func writeSample() async {
        let lyricCounts = await environment.lyricsService.currentCounters()
        guard let now = ProcessSample.now() else { return }
        var entry: [String: Any] = [
            "up": Int(now.date.timeIntervalSince(launched)),
            "memMB": Self.megabytes(now.footprint),
        ]
        if let last {
            let wall = max(now.date.timeIntervalSince(last.date), 1)
            entry["cpu"] = Self.rounded((now.cpuSeconds - last.cpuSeconds) / wall * 100, places: 2)
            // Times Brim was woken (timers, events): the energy cost of doing nothing. Two kernel counters.
            entry["wakeupsPerS"] = Self.rounded(Double(now.interruptWakeups - last.interruptWakeups) / wall, places: 2)
            entry["idleWakeupsPerS"] = Self.rounded(Double(now.idleWakeups - last.idleWakeups) / wall, places: 2)
        }
        last = now
        let nowPlaying = environment.nowPlaying
        entry["helperRestarts"] = nowPlaying.helper.restarts
        entry["helperRunning"] = nowPlaying.helper.processID != nil
        entry["nowPlaying"] = String(describing: nowPlaying.availability)
        entry["source"] = switch nowPlaying.source {
        case .system: "system"
        case .player(let player): player == .spotify ? "spotify" : "music"
        }
        entry["keys"] = String(describing: environment.keyTakeover.access)
        entry["keyPresses"] = environment.keyTakeover.handledPresses
        entry["macSleeps"] = sleeps
        entry["macWakes"] = systemWakes
        entry["screenChanges"] = screenChanges
        // Since launch: how often the second search rescued a miss, and how often it didn't.
        entry["lyricsAsked"] = lyricCounts.fromNetwork
        entry["lyricsRescued"] = lyricCounts.rescued
        entry["lyricsMadeTimed"] = lyricCounts.madeTimed
        entry["lyricsNotFound"] = lyricCounts.notFound
        let use = Usage.take()
        if !use.isEmpty { entry["use"] = use }
        sleeps = 0
        systemWakes = 0
        screenChanges = 0
        write(entry)
    }

    private func write(_ fields: [String: Any]) {
        var entry = fields
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current  // your local time, e.g. 2026-09-30T02:36:30+05:30
        entry["t"] = formatter.string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        let line = data + Data("\n".utf8)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: Self.url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: Self.url)
        }
    }

    /// The log's old place: moved (not copied, nothing lost) the first time, if the new place is still empty.
    private func moveFromLogsFolder() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: Self.oldURL.path), !fileManager.fileExists(atPath: Self.url.path) else { return }
        try? fileManager.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.moveItem(at: Self.oldURL, to: Self.url)
    }

    /// Keeps the file small: over 1 MB, the older half goes.
    private func trim() {
        guard let data = try? Data(contentsOf: Self.url), data.count > Self.sizeLimit else { return }
        let keep = data.suffix(Self.sizeLimit / 2)
        guard let firstBreak = keep.firstIndex(of: UInt8(ascii: "\n")) else { return }
        try? Data(keep[keep.index(after: firstBreak)...]).write(to: Self.url, options: .atomic)
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private static func megabytes(_ bytes: UInt64) -> NSDecimalNumber {
        rounded(Double(bytes) / 1_048_576, places: 1)
    }

    /// A decimal, so the file says 14.3 rather than 14.300000000000001.
    private static func rounded(_ value: Double, places: Int) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.\(places)f", value))
    }
}

/// This process's CPU time, idle wake-ups and memory, read from the kernel (`proc_pid_rusage`).
private struct ProcessSample {
    let date: Date
    let cpuSeconds: Double
    let idleWakeups: UInt64
    let interruptWakeups: UInt64
    let footprint: UInt64

    static func now() -> ProcessSample? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return nil }
        // CPU times come in Mach time units; the timebase turns them into nanoseconds.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(info.ri_user_time + info.ri_system_time)
        let nanoseconds = ticks * Double(timebase.numer) / Double(timebase.denom)
        return ProcessSample(date: Date(), cpuSeconds: nanoseconds / 1_000_000_000, idleWakeups: info.ri_pkg_idle_wkups,
                             interruptWakeups: info.ri_interrupt_wkups, footprint: info.ri_phys_footprint)
    }
}

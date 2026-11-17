#if DEBUG
import AppKit
import BrimCore
import BrimFeatures
import BrimSystem

/// Debug-only checks after your P-3 test (2026-09-29). Never in release builds.
@MainActor
enum P3Checks {
    static func startIfRequested(environment env: AppEnvironment) {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--position-check"), flag + 1 < args.count {
            let url = URL(fileURLWithPath: args[flag + 1])
            Task { await positionCheck(env, log: url) }
        }
        if let flag = args.firstIndex(of: "--activate-source"), flag + 1 < args.count {
            let url = URL(fileURLWithPath: args[flag + 1])
            Task { await activationCheck(env, log: url) }
        }
        if let flag = args.firstIndex(of: "--versions-check"), flag + 1 < args.count {
            let url = URL(fileURLWithPath: args[flag + 1])
            Task { await versionsCheck(env, log: url) }
        }
    }

    /// "Try Another Version" against the real LRCLIB, read-only (nothing is chosen or saved): the playing song,
    /// then "Easy", whose versions were compared by hand on 2026-09-29.
    private static func versionsCheck(_ env: AppEnvironment, log url: URL) async {
        try? await Task.sleep(for: .seconds(3))
        let service = LiveLyricsService(userAgent: AppEnvironment.userAgent)
        let easy = LyricsQuery(title: "Easy (with June Avery feat. Theo Marsh)", artist: "Sam Rowe",
                               album: "Easy (with June Avery feat. Theo Marsh)", duration: 213.571)
        for query in [env.nowPlaying.item.flatMap(LyricsQuery.init), easy].compactMap({ $0 }) {
            let started = Date()
            let result = await service.versions(for: query)
            var entry: [String: Any] = ["event": "versions", "title": query.title,
                                        "ms": Int(Date().timeIntervalSince(started) * 1000)]
            switch result {
            case .found(let versions):
                entry["count"] = versions.count
                entry["ids"] = versions.map(\.id)
                entry["firstLineTimes"] = versions.map { $0.lines.first(where: { !$0.text.isEmpty })?.time ?? -1 }
                entry["shifts"] = versions.map { version in
                    LRCLIBVersions.compare(version.lines, versions[0].lines).shift.map { ($0 * 100).rounded() / 100 } ?? 99
                }
                entry["coverage"] = versions.map { version in
                    (LRCLIBVersions.compare(version.lines, versions[0].lines).coverage * 100).rounded() / 100
                }
                entry["distinct"] = !versions.enumerated().contains { i, a in versions[(i + 1)...].contains { a.hasSameTiming(as: $0) } }
            case .offline: entry["result"] = "offline"
            case .rateLimited: entry["result"] = "rate-limited"
            case .failed(let reason): entry["result"] = "failed: \(reason)"
            }
            write(entry, to: url)
        }
        write(["event": "done"], to: url)
    }

    /// Every 2 s for 30 s: where Brim thinks the song is vs where the player says it is.
    /// A steady gap means macOS's Now Playing reports late (or early) for that player.
    private static func positionCheck(_ env: AppEnvironment, log url: URL) async {
        try? await Task.sleep(for: .seconds(3))
        let controls = AppleEventPlayerControls()
        for _ in 0..<15 {
            guard let item = env.nowPlaying.item,
                  let player = ScriptablePlayer(bundleID: item.sourceBundleIdentifier) else {
                write(["event": "skip", "reason": "not Spotify or Music"], to: url)
                return
            }
            let asked = Date()
            guard let actual = await controls.position(of: player) else { continue }
            // Compare at the middle of the round trip, when the player most likely read its clock.
            let middle = asked.addingTimeInterval(actual.roundTrip / 2)
            let computed = item.position(at: middle) ?? -1
            write(["event": "position", "app": player.rawValue, "title": item.title, "playing": item.isPlaying,
                   "brim": computed, "player": actual.seconds, "brimMinusPlayerMs": Int(((computed - actual.seconds) * 1000).rounded()),
                   "roundTripMs": Int(actual.roundTrip * 1000)], to: url)
            try? await Task.sleep(for: .seconds(2))
        }
        write(["event": "done"], to: url)
    }

    /// Brings the playing app to the front two ways, restoring your front app after each.
    private static func activationCheck(_ env: AppEnvironment, log url: URL) async {
        try? await Task.sleep(for: .seconds(3))
        guard let bundleID = env.nowPlaying.item?.sourceBundleIdentifier,
              let source = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let sourceURL = source.bundleURL,
              let original = NSWorkspace.shared.frontmostApplication else {
            write(["event": "skip", "reason": "nothing playing"], to: url)
            return
        }
        write(["event": "start", "source": bundleID, "frontBefore": original.bundleIdentifier ?? "?"], to: url)

        // A: ask LaunchServices to open the app (what a Dock click does).
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let startedA = Date()
        _ = try? await NSWorkspace.shared.openApplication(at: sourceURL, configuration: configuration)
        try? await Task.sleep(for: .milliseconds(800))
        write(["event": "A: NSWorkspace.openApplication", "frontAfter": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?",
               "ms": Int(Date().timeIntervalSince(startedA) * 1000) - 800], to: url)
        await restore(original)

        // B: ask the running app to come forward directly.
        let activated = source.activate()
        try? await Task.sleep(for: .milliseconds(800))
        write(["event": "B: NSRunningApplication.activate", "accepted": activated,
               "frontAfter": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"], to: url)
        await restore(original)
        write(["event": "done", "frontAtEnd": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"], to: url)
    }

    private static func restore(_ app: NSRunningApplication) async {
        guard let url = app.bundleURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        try? await Task.sleep(for: .milliseconds(800))
    }

    private static func write(_ entry: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8).map({ $0 + "\n" }) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
#endif

#if DEBUG
import AppKit
import BrimCore
import BrimSystem

/// Debug only: `--queue-check <file>` asks Music and Spotify for their queues (read-only: nothing plays or changes)
/// and writes what came back as counts, never song names (2026-10-29). Brim quits after.
enum QueueCheck {
    static func startIfRequested(environment env: AppEnvironment) {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--queue-check"), flag + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[flag + 1])
        Task {
            var report: [String: String] = [:]
            for player in ScriptablePlayer.allCases {
                let started = Date()
                let answer = await env.playerControls.queue(of: player)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                if case .items(_, let items) = answer, player == .music {
                    var found = 0
                    for item in items.prefix(5) where await env.playerControls.cover(of: item, in: .music) != nil { found += 1 }
                    report["music covers (first 5)"] = "\(found)"
                }
                report[player.rawValue] = switch answer {
                case .items(let source, let items):
                    "items \(items.count), named: \(source != nil), covers: \(items.filter { $0.artworkURL != nil || $0.sameAlbumAsPlaying }.count), \(ms) ms"
                case .shuffled: "shuffled, \(ms) ms"
                case .musicLibraryOnly: "not from your Library (no playlist to share), \(ms) ms"
                case .spotifyNotConnected: "not connected"
                case .unavailable: "unavailable"
                case .empty: "empty (or not running), \(ms) ms"
                case .loading: "loading"
                }
            }
            let free = await env.playerControls.spotifyAnnouncementByScript()
            report["spotify free: state/title/duration/id"] =
                "\(free.map { String(describing: $0.state) } ?? "none") / \(free?.title != nil) / \(free?.duration.map { Int($0) } ?? -1) s / \(free?.trackID != nil)"
            if let id = free?.trackID {
                report["spotify free: cover address"] = "\(await env.playerControls.spotifyCoverURL(for: id)?.host ?? "none")"
            }
            if args.contains("--modes-check") { report.merge(await modesCheck(env.playerControls)) { $1 } }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out)
            }
            NSApp.terminate(nil)
        }
    }

    /// `--modes-check` (with --queue-check, your ask 2026-10-29): for each running player, flips Shuffle and Repeat
    /// once through Brim's own path, reads them back after 1.5 s, then puts them back as they were. Values only.
    private static func modesCheck(_ controls: AppleEventPlayerControls) async -> [String: String] {
        var out: [String: String] = [:]
        for player in ScriptablePlayer.allCases {
            guard let before = await controls.modes(of: player, track: nil) else { out["modes \(player.rawValue)"] = "no answer"; continue }
            let shuffleSent = await controls.setShuffle(!before.shuffle, in: player)
            try? await Task.sleep(for: .seconds(1.5))
            let afterShuffle = await controls.modes(of: player, track: nil)
            _ = await controls.setShuffle(before.shuffle, in: player)
            try? await Task.sleep(for: .seconds(1))
            let target: RepeatMode = before.repeatMode == .off ? .all : .off
            let repeatSent = await controls.setRepeat(target, in: player)
            try? await Task.sleep(for: .seconds(1.5))
            let afterRepeat = await controls.modes(of: player, track: nil)
            _ = await controls.setRepeat(before.repeatMode, in: player)
            try? await Task.sleep(for: .seconds(1))
            let restored = await controls.modes(of: player, track: nil)
            out["modes \(player.rawValue)"] = "before shuffle \(before.shuffle) repeat \(before.repeatMode) canChange \(before.canChange); "
                + "shuffle sent \(shuffleSent) → \(afterShuffle.map { "\($0.shuffle)" } ?? "?"); "
                + "repeat \(target) sent \(repeatSent) → \(afterRepeat.map { "\($0.repeatMode)" } ?? "?"); "
                + "restored shuffle \(restored.map { "\($0.shuffle)" } ?? "?") repeat \(restored.map { "\($0.repeatMode)" } ?? "?")"
        }
        return out
    }
}
#endif

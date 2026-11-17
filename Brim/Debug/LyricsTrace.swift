#if DEBUG
import Foundation
import BrimCore
import BrimFeatures

/// Debug-only proof of lyric timing (P-3). Never in release builds.
///
/// Launch with `--lyrics-trace <log.jsonl>` while a song plays. It tracks lines as if lyrics were on screen
/// and logs, for every line switch, how late it happened: the song position at the switch minus the line's time.
/// The PRD target is ±0.15 s. It also logs what the lookup found.
@MainActor
enum LyricsTrace {
    static func startIfRequested(environment env: AppEnvironment) {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--lyrics-trace"), flag + 1 < args.count else { return }
        let url = URL(fileURLWithPath: args[flag + 1])
        env.lyrics.onLineSwitch = { lineTime, position in
            write(["event": "line", "lineTime": lineTime, "position": position,
                   "lateMs": Int(((position - lineTime) * 1000).rounded())], to: url)
        }
        env.lyrics.beginDisplay()
        observe {
            let status = env.lyrics.status
            var entry: [String: Any] = ["event": "status", "status": String(describing: status)]
            // What the lookup was for (2026-10-30: Apple Music songs resumed after a pause found no lyrics).
            if let item = env.nowPlaying.item {
                entry["app"] = item.sourceBundleIdentifier ?? "?"
                entry["title"] = item.title
                entry["artist"] = item.artist ?? "-"
                entry["album"] = item.album ?? "-"
                entry["duration"] = item.duration ?? -1
                entry["elapsed"] = item.elapsed ?? -1
                entry["playing"] = item.isPlaying
            }
            switch env.lyrics.lyrics {
            case .synced(let lines): entry["lines"] = lines.count
            case .plain: entry["kind"] = "plain"
            case .instrumental: entry["kind"] = "instrumental"
            case nil: break
            }
            write(entry, to: url)
        }
    }

    private static func write(_ entry: [String: Any], to url: URL) {
        var entry = entry
        entry["at"] = Date.now.timeIntervalSince1970
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

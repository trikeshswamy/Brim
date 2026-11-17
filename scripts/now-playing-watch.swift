// Passive recorder for Now Playing compatibility debugging: prints macOS Now Playing as the helper sees it (no artwork
// bytes) and Spotify's own announcements, with millisecond times. Sends no commands.
//
//   swift scripts/now-playing-watch.swift [seconds]      (default 600)
//
// Needs a built build/Brim.app (it runs the bundled helper). Start it after Brim: Brim's launch-time orphan cleanup
// stops any other helper stream. Prints song titles: keep its output on your Mac.
import AppKit
import Foundation

let framework = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("build/Brim.app/Contents/Frameworks/MediaRemoteAdapter.framework").path
let script = framework + "/Versions/A/Resources/mediaremote-adapter.pl"
let clock = DateFormatter()
clock.dateFormat = "HH:mm:ss.SSS"
setvbuf(stdout, nil, _IOLBF, 0)

let helper = Process()
helper.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
// Keep the missing-title opt-in here so the probe can distinguish a titleless
// session from no MediaRemote session at all. Brim's parser still requires a
// title before it can show a useful island item.
helper.arguments = [script, framework, "stream", "--micros", "--debounce=100", "--allow-missing-title"]
let pipe = Pipe()
helper.standardOutput = pipe
helper.standardError = FileHandle.nullDevice
try helper.run()

Task.detached {
    let keys = [
        "title", "artist", "album", "playing", "duration", "elapsedTime", "bundleIdentifier",
        "parentApplicationBundleIdentifier", "processIdentifier", "mediaType", "playbackRate"
    ]
    do {
        for try await line in pipe.fileHandleForReading.bytes.lines {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            let payload = object["payload"] as? [String: Any] ?? [:]
            if payload.isEmpty {
                print(clock.string(from: .now), "MR no-session-or-incomplete-payload")
                continue
            }
            let fields = keys.compactMap { key in payload[key].map { "\(key)=\($0)" } }.joined(separator: " | ")
            print(clock.string(from: .now), "MR", "diff=\(object["diff"] ?? "-")", "art=\(payload["artworkData"] != nil)", fields)
        }
    } catch {
        print("The helper's output stopped: \(error.localizedDescription)")
    }
}
DistributedNotificationCenter.default().addObserver(
    forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { note in
    let info = note.userInfo ?? [:]
    let keys = ["Name", "Artist", "Album", "Player State", "Duration", "Playback Position"]
    print(clock.string(from: .now), "SP", keys.compactMap { key in info[key].map { "\(key)=\($0)" } }.joined(separator: " | "))
}
print(clock.string(from: .now), "watching")
RunLoop.main.run(until: .now.addingTimeInterval(Double(CommandLine.arguments.dropFirst().first ?? "") ?? 600))
helper.terminate()

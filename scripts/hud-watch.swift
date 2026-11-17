// hud-watch: for N seconds, logs every window that appears above normal apps and isn't Brim's
// (Apple's volume/brightness HUD shows up here). Reads the window list only: no permission needed.
// Usage: swift hud-watch.swift <seconds>
import AppKit

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "60") ?? 60
let start = Date()
var seen: [Int: String] = [:]
print("watching for \(Int(seconds)) s…")
while Date().timeIntervalSince(start) < seconds {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var now: [Int: String] = [:]
    for window in list {
        guard let number = window[kCGWindowNumber as String] as? Int,
              let layer = window[kCGWindowLayer as String] as? Int, layer > 0,
              let owner = window[kCGWindowOwnerName as String] as? String, owner != "Brim" else { continue }
        let b = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
        now[number] = "\(owner) layer \(layer) at \(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0))×\(Int(b["Height"] ?? 0))"
    }
    for (number, description) in now where seen[number] == nil {
        print(String(format: "%6.2f s  APPEARED  ", Date().timeIntervalSince(start)) + description)
    }
    for (number, description) in seen where now[number] == nil {
        print(String(format: "%6.2f s  gone      ", Date().timeIntervalSince(start)) + description)
    }
    seen = now
    Thread.sleep(forTimeInterval: 0.1)
}
print("done")

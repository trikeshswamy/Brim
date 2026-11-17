#if DEBUG
import AppKit
import BrimCore
import BrimFeatures
import BrimSystem

/// Debug-only verification loop for the key takeover (2026-09-29). Never in release builds.
///
/// Launch with `--self-test-keys <log.jsonl>`. It posts real media-key events and, for each one, records:
/// - whether Brim handled it, and whether the level moved to the expected 5% / 2% step;
/// - whether Brim's HUD showed;
/// - any other app's window that appeared at the top (Apple's HUD).
/// Two "control" presses go to macOS on purpose first, to prove Apple's HUD is detectable at all.
/// Your volume, mute, and brightness are put back at the end.
@MainActor
final class KeySelfTest {
    private let env: AppEnvironment
    private let logURL: URL
    private var results: [Bool] = []

    static func startIfRequested(environment: AppEnvironment) {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--self-test-keys"), flag + 1 < args.count else { return }
        let test = KeySelfTest(env: environment, logURL: URL(fileURLWithPath: args[flag + 1]))
        Task { await test.run() }
    }

    private init(env: AppEnvironment, logURL: URL) {
        self.env = env
        self.logURL = logURL
    }

    /// Who draws Apple's volume/brightness HUD: MenuBarAgent on macOS 27 (seen in the control presses),
    /// OSDUIHelper or ControlCenter on earlier versions. Other apps' pop-ups (e.g. Grammarly, run 4) are logged, not failed.
    private static let appleHUDOwners: Set<String> = ["MenuBarAgent", "OSDUIHelper", "ControlCenter"]

    private enum Key: Int {
        case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
        var isVolume: Bool { self != .brightnessUp && self != .brightnessDown }
        var hud: HUDKind { isVolume ? .volume : .brightness }
    }

    private func run() async {
        write(["event": "start"])
        for _ in 0..<20 where env.keyTakeover.access != .active {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard env.keyTakeover.access == .active else {
            write(["event": "abort", "reason": "key access is \(env.keyTakeover.access)"])
            return
        }
        let originalVolume = env.volumeService.currentState()
        let originalBrightness = env.brightnessService.level()
        try? await Task.sleep(for: .seconds(2))  // let the launch settle

        // Expected levels are written out by hand (not computed by LevelStep), so a bug in the step math can't
        // hide behind a matching expectation. Each group starts from a known level that isn't exact in a
        // 32-bit float, which is what exposed the "80% → 80%" bug in run 2.
        await press("control: volume up to macOS", .volumeUp, fine: false, control: true)
        env.volumeService.setLevel(0.80)
        try? await Task.sleep(for: .milliseconds(300))
        await press("volume up 5%", .volumeUp, fine: false, expect: 0.85)
        await press("volume down 5%", .volumeDown, fine: false, expect: 0.80)
        await press("volume up 2% (⌥⇧)", .volumeUp, fine: true, expect: 0.82)
        await press("volume down 2% (⌥⇧)", .volumeDown, fine: true, expect: 0.80)
        await press("mute", .mute, fine: false)
        await press("unmute", .mute, fine: false)
        await press("control: brightness up to macOS", .brightnessUp, fine: false, control: true)
        env.brightnessService.setLevel(0.60)
        try? await Task.sleep(for: .milliseconds(300))
        await press("brightness up 5%", .brightnessUp, fine: false, expect: 0.65)
        await press("brightness down 5%", .brightnessDown, fine: false, expect: 0.60)
        await press("brightness up 2% (⌥⇧)", .brightnessUp, fine: true, expect: 0.62)
        await press("brightness down 2% (⌥⇧)", .brightnessDown, fine: true, expect: 0.60)

        if let originalVolume {
            env.volumeService.setLevel(originalVolume.level)
            env.volumeService.setMuted(originalVolume.isMuted)
        }
        if let originalBrightness { env.brightnessService.setLevel(originalBrightness) }
        write(["event": "summary", "passed": results.filter { $0 }.count, "total": results.count])
    }

    private func press(_ name: String, _ key: Key, fine: Bool, control: Bool = false, expect: Double? = nil) async {
        let windowsBefore = otherWindows()
        let levelBefore = level(key)
        let mutedBefore = env.volumeService.currentState()?.isMuted
        let handledBefore = env.keyTakeover.handledPresses
        env.keyTakeover.passThrough = control

        post(key, down: true, fine: fine)
        post(key, down: false, fine: fine)

        // Brim's HUD and the level are read at 0.45 s. Other windows are watched every 0.1 s for 1.5 s,
        // so a late Apple HUD is caught too (run 3 missed one with a single look at 0.45 s).
        var appearedByNumber: [Int: [String: Any]] = [:]
        var hudShown = false
        var levelAfter: Double?
        for tick in 1...15 {
            try? await Task.sleep(for: .milliseconds(100))
            for (number, window) in otherWindows() where windowsBefore[number] == nil {
                appearedByNumber[number] = window
            }
            if tick == 4 {
                hudShown = env.hud.showing == key.hud
                levelAfter = level(key)
            }
        }
        let isAppleHUD = { (window: [String: Any]) in Self.appleHUDOwners.contains(window["owner"] as? String ?? "") }
        let appeared = appearedByNumber.values.filter(isAppleHUD)
        let unrelated = appearedByNumber.values.filter { !isAppleHUD($0) }
        let handled = env.keyTakeover.handledPresses - handledBefore
        env.keyTakeover.passThrough = false

        var entry: [String: Any] = ["case": name, "handledByBrim": handled, "brimHUD": hudShown,
                                    "appleHUD": appeared, "unrelatedWindows": unrelated,
                                    "before": levelBefore ?? -1, "after": levelAfter ?? -1]
        let pass: Bool
        if control {
            pass = handled == 0 && !appeared.isEmpty  // macOS handled it and its HUD was seen
        } else if key == .mute {
            let mutedAfter = env.volumeService.currentState()?.isMuted
            entry["mutedAfter"] = mutedAfter ?? false
            pass = handled == 1 && appeared.isEmpty && hudShown && mutedAfter == !(mutedBefore ?? false)
        } else {
            let expected = expect ?? -1
            entry["expected"] = expected
            pass = handled == 1 && appeared.isEmpty && hudShown && abs((levelAfter ?? -1) - expected) < 0.002
        }
        entry["pass"] = pass
        results.append(pass)
        write(entry)
        try? await Task.sleep(for: .milliseconds(1200))  // let both HUDs leave the screen before the next press
    }

    private func level(_ key: Key) -> Double? {
        key.isVolume ? env.volumeService.currentState()?.level : env.brightnessService.level()
    }

    /// Posts the same event a keyboard's media key produces (system-defined, subtype 8).
    private func post(_ key: Key, down: Bool, fine: Bool) {
        var flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
        if fine { flags.formUnion([.option, .shift]) }
        let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: 0, context: nil, subtype: 8,
                                       data1: key.rawValue << 16 | (down ? 0xA : 0xB) << 8, data2: -1)
        event?.cgEvent?.post(tap: .cghidEventTap)
    }

    /// On-screen windows above normal apps that don't belong to Brim, by window number.
    private func otherWindows() -> [Int: [String: Any]] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var found: [Int: [String: Any]] = [:]
        for window in list {
            guard let number = window[kCGWindowNumber as String] as? Int,
                  let layer = window[kCGWindowLayer as String] as? Int, layer > 0,
                  let owner = window[kCGWindowOwnerName as String] as? String, owner != "Brim" else { continue }
            let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
            found[number] = ["owner": owner, "layer": layer,
                             "frame": "\(Int(bounds["X"] ?? 0)),\(Int(bounds["Y"] ?? 0)) \(Int(bounds["Width"] ?? 0))×\(Int(bounds["Height"] ?? 0))"]
        }
        return found
    }

    private func write(_ entry: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8).map({ $0 + "\n" }) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}
#endif

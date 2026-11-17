#if DEBUG
import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio
import CoreServices
import BrimCore
import BrimFeatures
import BrimSystem

/// Debug-only validation for side controls and the output picker (approved 2026-09-29). Never in release builds.
///
/// Launch with `--validate-controls <log.jsonl>` while Spotify or Music is playing. For the playing app it checks:
/// 1. the Automation permission (macOS asks once: "Brim wants to control Spotify");
/// 2. reading shuffle and repeat through AppleScript, and how long a read takes;
/// 3. changing each through AppleScript, then putting it back;
/// 4. whether the app also obeys shuffle / repeat sent through macOS's Now Playing route (no permission);
/// 5. switching the sound output to another device for 1.5 s, then back.
/// Everything it changes is restored.
@MainActor
final class ControlsValidation {
    private let env: AppEnvironment
    private let logURL: URL

    static func startIfRequested(environment: AppEnvironment) {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--signin-listener-check"), flag + 1 < args.count {
            // The Spotify sign-in's local half: Brim's listener on 127.0.0.1:42813 gets a browser-style reply it sends itself.
            let check = ControlsValidation(env: environment, logURL: URL(fileURLWithPath: args[flag + 1]))
            Task {
                let result = await SpotifyWebAPI.listenerSelfTest()
                check.write(["event": "listener", "result": result])
            }
            return
        }
        if let flag = args.firstIndex(of: "--spotify-mr-experiment"), flag + 1 < args.count {
            // Your request (2026-10-02): Shuffle & Repeat from anywhere. Does Spotify 1.3.3 take macOS's own repeat and
            // shuffle commands (the Now Playing route Apple Music uses)? Sends each once while Spotify is the Now
            // Playing app, reads its menu's checkmarks 1.5 s later, and puts the setting back. Never touches playback.
            let experiment = ControlsValidation(env: environment, logURL: URL(fileURLWithPath: args[flag + 1]))
            Task { await experiment.spotifyNowPlayingModesExperiment() }
            return
        }
        if let flag = args.firstIndex(of: "--spotify-web-probe"), flag + 1 < args.count {
            // Your request (2026-10-02): Shuffle & Repeat from anywhere. Spotify's menu refuses in the background, so can
            // Accessibility see the shuffle and repeat buttons in Spotify's own window? Reads only. If they're hidden, it
            // switches Spotify's accessibility on (what VoiceOver does) for 15 s, then off. Presses nothing.
            let probe = ControlsValidation(env: environment, logURL: URL(fileURLWithPath: args[flag + 1]))
            Task { await probe.spotifyWebProbe() }
            return
        }
        if let flag = args.firstIndex(of: "--spotify-cover-probe"), flag + 2 < args.count {
            // 0.17.3: one cover through the Web API, the way the store asks for it, twice (the second shows the time
            // without the first connection). Logs times, bytes and pixel size only: no track ID, no address.
            let probe = ControlsValidation(env: environment, logURL: URL(fileURLWithPath: args[flag + 1]))
            let uri = args[flag + 2]
            Task {
                for attempt in 1...2 {
                    let started = Date()
                    let cover = await environment.spotifyWeb.cover(forTrack: uri)
                    let image = cover.flatMap { NSImage(data: $0) }
                    probe.write(["event": "cover", "attempt": attempt, "ms": Int(Date().timeIntervalSince(started) * 1000),
                                 "bytes": cover?.count ?? 0,
                                 "pixels": image?.representations.first.map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "none"])
                }
            }
            return
        }
        if let flag = args.firstIndex(of: "--spotify-modes-experiment"), flag + 1 < args.count {
            // Your request (2026-10-02): make Spotify's Shuffle & Repeat work through its Playback menu. Toggles each
            // once and puts it back exactly, logging the menu's checkmarks right after (are they current?) and how many
            // presses bring Repeat back (2 or 3 steps). Never touches playback. Also logs the keys of Spotify's own
            // announcements meanwhile (values only for state/shuffle/repeat keys: no titles).
            let experiment = ControlsValidation(env: environment, logURL: URL(fileURLWithPath: args[flag + 1]))
            // `--force`: press Shuffle once even when the menu says it's disabled, to learn whether that's real.
            Task { await experiment.spotifyModesExperiment(force: args.contains("--force")) }
            return
        }
        if let flag = args.firstIndex(of: "--ax-probe"), flag + 1 < args.count {
            // Read-only (2026-10-02): what Accessibility shows of Spotify's Playback menu (titles, shortcuts, checkmarks,
            // enabled) and whether the front window is full screen. Nothing is pressed or opened.
            let probe = ControlsValidation(env: environment, logURL: URL(fileURLWithPath: args[flag + 1]))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { probe.axProbe() }
            return
        }
        if let flag = args.firstIndex(of: "--safari-ax-probe"), flag + 1 < args.count {
            // Read-only: measure what Safari exposes for website media through Accessibility. It deliberately records
            // control labels and numeric ranges only, never page text, URLs, tab titles, or entered content.
            let probe = ControlsValidation(env: environment, logURL: URL(fileURLWithPath: args[flag + 1]))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { probe.safariAXProbe() }
            return
        }
        if let flag = args.firstIndex(of: "--reach-check"), flag + 1 < args.count {
            // Read-only: asks a running Spotify for its shuffle and repeat 3 times in a row and logs how long each took.
            // While it isn't answering (Spotify 1.3.3, 2026-10-02), the first waits its 2 s, the next two fail at once.
            let checker = ControlsValidation(env: environment, logURL: URL(fileURLWithPath: args[flag + 1]))
            Task {
                guard !NSRunningApplication.runningApplications(withBundleIdentifier: ScriptablePlayer.spotify.rawValue).isEmpty else {
                    checker.write(["event": "abort", "reason": "Spotify isn't running"])
                    return
                }
                for attempt in 1...3 {
                    let started = Date()
                    let modes = await environment.playerControls.modes(of: .spotify)
                    checker.write(["event": "reach", "attempt": attempt, "answered": modes != nil,
                                   "ms": Int(Date().timeIntervalSince(started) * 1000)])
                }
            }
            return
        }
        if let flag = args.firstIndex(of: "--read-controls"), flag + 1 < args.count {
            // Read-only: logs the playing app's shuffle and repeat, changes nothing.
            let reader = ControlsValidation(env: environment, logURL: URL(fileURLWithPath: args[flag + 1]))
            Task { await reader.readOnly() }
            return
        }
        guard let flag = args.firstIndex(of: "--validate-controls"), flag + 1 < args.count else { return }
        let validation = ControlsValidation(env: environment, logURL: URL(fileURLWithPath: args[flag + 1]))
        Task { await validation.run() }
    }

    private func spotifyNowPlayingModesExperiment() async {
        try? await Task.sleep(for: .seconds(3))  // the helper starts; the menu becomes readable
        let controls = env.playerControls
        func read(_ label: String) async -> PlayerModes? {
            let modes = await controls.modes(of: .spotify)
            write(["event": "read", "at": label, "shuffle": modes.map { $0.shuffle ? "on" : "off" } ?? "?",
                   "repeat": modes.map { $0.repeatMode == .off ? "off" : "on" } ?? "?",
                   "front": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"])
            return modes
        }
        guard let start = await read("start") else { return write(["event": "abort", "reason": "can't read Spotify's menu"]) }
        // Repeat through macOS: off → all, or on → off (put back after).
        let repeatTarget: RepeatMode = start.repeatMode == .off ? .all : .off
        await env.nowPlayingService.setRepeat(repeatTarget)
        try? await Task.sleep(for: .seconds(1.5))
        let afterRepeat = await read("repeat sent")
        let repeatTook = (afterRepeat?.repeatMode == .off) == (repeatTarget == .off)
        write(["event": "repeat-result", "took": repeatTook])
        if repeatTook {
            await env.nowPlayingService.setRepeat(start.repeatMode == .off ? .off : .all)
            try? await Task.sleep(for: .seconds(1.5))
            _ = await read("repeat restored")
        }
        // Shuffle through macOS: flipped, then put back.
        await env.nowPlayingService.setShuffle(!start.shuffle)
        try? await Task.sleep(for: .seconds(1.5))
        let afterShuffle = await read("shuffle sent")
        let shuffleTook = afterShuffle?.shuffle == !start.shuffle
        write(["event": "shuffle-result", "took": shuffleTook])
        if shuffleTook {
            await env.nowPlayingService.setShuffle(start.shuffle)
            try? await Task.sleep(for: .seconds(1.5))
            _ = await read("shuffle restored")
        }
        write(["event": "end"])
    }

    private func spotifyWebProbe() async {
        func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
            var result: AnyObject?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
        }
        func children(_ element: AXUIElement) -> [AXUIElement] { (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
        guard let spotify = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first else {
            return write(["event": "abort", "reason": "Spotify isn't running"])
        }
        let app = AXUIElementCreateApplication(spotify.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 2)
        func scan(_ mode: String) -> Int {
            var queue: [(AXUIElement, Int)] = ((value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).map { ($0, 0) }
            var nodes = 0, webAreas = 0
            var found: [[String: Any]] = []
            let started = Date()
            while !queue.isEmpty, nodes < 8000, Date().timeIntervalSince(started) < 8 {
                let (element, depth) = queue.removeFirst()
                nodes += 1
                let role = value(element, kAXRoleAttribute) as? String ?? ""
                if role == "AXWebArea" { webAreas += 1 }
                let text = [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute]
                    .compactMap { value(element, $0) as? String }.filter { !$0.isEmpty }.joined(separator: " | ")
                let lower = text.lowercased()
                if lower.contains("shuffle") || lower.contains("repeat") {
                    var actions: CFArray?
                    AXUIElementCopyActionNames(element, &actions)
                    found.append(["role": role, "text": text, "value": value(element, kAXValueAttribute).map { "\($0)" } ?? "nil",
                                  "enabled": value(element, kAXEnabledAttribute) as? Bool ?? false,
                                  "actions": (actions as? [String]) ?? [], "depth": depth])
                }
                if depth < 80 { queue.append(contentsOf: children(element).map { ($0, depth + 1) }) }
            }
            write(["event": "scan", "mode": mode, "nodes": nodes, "webAreas": webAreas, "found": found,
                   "ms": Int(Date().timeIntervalSince(started) * 1000)])
            return found.count
        }
        var hits = scan("as is")
        if hits == 0 {
            let set = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            write(["event": "set", "attribute": "AXManualAccessibility", "result": Int(set.rawValue)])
            try? await Task.sleep(for: .seconds(2))
            hits = scan("manual")
        }
        if hits == 0 {
            let set = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            write(["event": "set", "attribute": "AXEnhancedUserInterface", "result": Int(set.rawValue)])
            try? await Task.sleep(for: .seconds(2))
            hits = scan("enhanced")
        }
        write(["event": "hold", "seconds": 15])
        try? await Task.sleep(for: .seconds(15))
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanFalse)
        write(["event": "reset"])
    }

    private func spotifyModesExperiment(force: Bool = false) async {
        func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
            var result: AnyObject?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
        }
        func children(_ element: AXUIElement) -> [AXUIElement] { (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
        func key(_ item: AXUIElement) -> (Int, Int, String) {
            ((value(item, kAXMenuItemCmdVirtualKeyAttribute) as? NSNumber)?.intValue ?? -1,
             (value(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue ?? -1,
             value(item, kAXMenuItemCmdCharAttribute) as? String ?? "")
        }
        guard let spotify = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first else {
            return write(["event": "abort", "reason": "Spotify isn't running"])
        }
        let app = AXUIElementCreateApplication(spotify.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let barValue = value(app, kAXMenuBarAttribute) else { return write(["event": "abort", "reason": "no menu bar"]) }
        let bar = barValue as! AXUIElement
        var menuItems: [AXUIElement] = []
        for barItem in children(bar) {
            guard let menu = children(barItem).first else { continue }
            let items = children(menu)
            if items.contains(where: { key($0).0 == 124 && key($0).1 == 0 }) { menuItems = items; break }
        }
        guard let first = menuItems.first,
              let shuffle = menuItems.first(where: { key($0).2 == "S" && key($0).1 == 0 }),
              let repeatItem = menuItems.first(where: { key($0).2 == "R" && key($0).1 == 0 }) else {
            return write(["event": "abort", "reason": "Playback menu items not found"])
        }
        func snapshot(_ label: String) {
            write(["event": "state", "at": label, "play": value(first, kAXTitleAttribute) as? String ?? "",
                   "shuffleMark": value(shuffle, kAXMenuItemMarkCharAttribute) as? String ?? "",
                   "shuffleEnabled": value(shuffle, kAXEnabledAttribute) as? Bool ?? false,
                   "shuffleTitle": value(shuffle, kAXTitleAttribute) as? String ?? "",
                   "repeatMark": value(repeatItem, kAXMenuItemMarkCharAttribute) as? String ?? "",
                   "repeatEnabled": value(repeatItem, kAXEnabledAttribute) as? Bool ?? false,
                   "repeatTitle": value(repeatItem, kAXTitleAttribute) as? String ?? ""])
        }
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            var entry: [String: Any] = ["event": "announcement", "keys": info.keys.map { "\($0)" }.sorted()]
            for (k, v) in info where "\(k)".range(of: "shuffl|repeat|state", options: [.regularExpression, .caseInsensitive]) != nil {
                entry["\(k)"] = "\(v)"
            }
            MainActor.assumeIsolated { self?.write(entry) }
        }
        defer { DistributedNotificationCenter.default().removeObserver(observer) }
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        let mark = { (item: AXUIElement) in value(item, kAXMenuItemMarkCharAttribute) as? String ?? "" }
        snapshot("start")
        if value(shuffle, kAXEnabledAttribute) as? Bool == true {
            let original = mark(shuffle)
            AXUIElementPerformAction(shuffle, kAXPressAction as CFString)
            snapshot("shuffle pressed +0")
            await pause(0.3); snapshot("shuffle pressed +0.3")
            await pause(0.7); snapshot("shuffle pressed +1.0")
            AXUIElementPerformAction(shuffle, kAXPressAction as CFString)
            await pause(1.0); snapshot("shuffle pressed again +1.0")
            write(["event": "shuffle-restored", "value": mark(shuffle) == original])
        } else if force {
            // Disabled in the menu: does a press still work? Pressed once; if the checkmark moves, pressed again.
            let original = mark(shuffle)
            let result = AXUIElementPerformAction(shuffle, kAXPressAction as CFString)
            write(["event": "forced-press", "axResult": Int(result.rawValue)])
            await pause(0.3); snapshot("forced shuffle +0.3")
            await pause(0.7); snapshot("forced shuffle +1.0")
            if mark(shuffle) != original {
                AXUIElementPerformAction(shuffle, kAXPressAction as CFString)
                await pause(1.0); snapshot("forced shuffle restored +1.0")
            }
            write(["event": "forced-shuffle", "changed": mark(shuffle) != original ? "stuck changed" : "unchanged or restored"])
        } else {
            write(["event": "shuffle-skipped", "reason": "disabled"])
        }
        if value(repeatItem, kAXEnabledAttribute) as? Bool == true {
            let original = mark(repeatItem)
            var presses = 0
            repeat {
                AXUIElementPerformAction(repeatItem, kAXPressAction as CFString)
                presses += 1
                await pause(1.0)
                snapshot("repeat press \(presses) +1.0")
            } while mark(repeatItem) != original && presses < 3
            write(["event": "repeat-restored", "value": mark(repeatItem) == original, "presses": presses])
        } else {
            write(["event": "repeat-skipped", "reason": "disabled"])
        }
        await pause(0.5)
        snapshot("end")
    }

    private func axProbe() {
        func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
            var result: AnyObject?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
        }
        func children(_ element: AXUIElement) -> [AXUIElement] { (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
        write(["event": "trusted", "value": AXIsProcessTrusted()])
        if let spotify = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first {
            let app = AXUIElementCreateApplication(spotify.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 1)
            let menuBar = value(app, kAXMenuBarAttribute).map { $0 as! AXUIElement }
            let titles = menuBar.map { children($0).compactMap { value($0, kAXTitleAttribute) as? String } } ?? []
            write(["event": "spotify-menus", "titles": titles])
            if let bar = menuBar, let playback = children(bar).first(where: { (value($0, kAXTitleAttribute) as? String) == "Playback" }),
               let menu = children(playback).first {
                for item in children(menu) {
                    var entry: [String: Any] = ["event": "spotify-item"]
                    entry["title"] = value(item, kAXTitleAttribute) as? String ?? ""
                    entry["enabled"] = value(item, kAXEnabledAttribute) as? Bool ?? false
                    entry["cmdChar"] = value(item, kAXMenuItemCmdCharAttribute) as? String ?? ""
                    entry["cmdGlyph"] = (value(item, kAXMenuItemCmdGlyphAttribute) as? NSNumber)?.intValue ?? -1
                    entry["cmdKey"] = (value(item, kAXMenuItemCmdVirtualKeyAttribute) as? NSNumber)?.intValue ?? -1
                    entry["cmdModifiers"] = (value(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue ?? -1
                    entry["mark"] = value(item, kAXMenuItemMarkCharAttribute) as? String ?? ""
                    write(entry)
                }
            }
        } else {
            write(["event": "spotify-menus", "titles": [], "note": "Spotify isn't running"])
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            let app = AXUIElementCreateApplication(front.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 1)
            let window = value(app, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
            let full = window.flatMap { value($0, "AXFullScreen") as? Bool }
            write(["event": "front", "app": front.bundleIdentifier ?? "?", "hasWindow": window != nil,
                   "fullScreen": full.map { $0 ? "yes" : "no" } ?? "unknown"])
        }
    }

    private func safariAXProbe() {
        func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
            var result: AnyObject?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
        }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        func text(_ element: AXUIElement) -> String {
            [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute, kAXIdentifierAttribute]
                .compactMap { value(element, $0) as? String }
                .joined(separator: " | ")
        }
        guard let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first else {
            return write(["event": "abort", "reason": "Safari isn't running"])
        }
        let app = AXUIElementCreateApplication(safari.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        let roots = (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var queue = roots.map { ($0, 0) }
        var nodes = 0
        var webAreas = 0
        var mediaControls: [[String: Any]] = []
        let started = Date()
        while !queue.isEmpty, nodes < 20_000, Date().timeIntervalSince(started) < 5 {
            let (element, depth) = queue.removeFirst()
            nodes += 1
            let role = value(element, kAXRoleAttribute) as? String ?? ""
            if role == "AXWebArea" { webAreas += 1 }
            let label = text(element)
            let lower = label.lowercased()
            let mediaLabel = ["play video", "pause video", "play", "pause", "seek", "progress", "previous", "next"]
                .contains { lower.contains($0) }
            if mediaLabel || role == "AXSlider" {
                var entry: [String: Any] = [
                    "role": role,
                    "label": label,
                    "enabled": value(element, kAXEnabledAttribute) as? Bool ?? false,
                    "depth": depth
                ]
                if let raw = value(element, kAXValueAttribute) { entry["valueType"] = String(describing: type(of: raw)) }
                if let raw = value(element, kAXMinValueAttribute) { entry["minType"] = String(describing: type(of: raw)) }
                if let raw = value(element, kAXMaxValueAttribute) { entry["maxType"] = String(describing: type(of: raw)) }
                var actions: CFArray?
                AXUIElementCopyActionNames(element, &actions)
                entry["actions"] = (actions as? [String]) ?? []
                mediaControls.append(entry)
            }
            if depth < 80 { queue.append(contentsOf: children(element).map { ($0, depth + 1) }) }
        }
        write(["event": "safari-ax", "trusted": AXIsProcessTrusted(), "windows": roots.count,
               "nodes": nodes, "webAreas": webAreas, "controls": mediaControls,
               "ms": Int(Date().timeIntervalSince(started) * 1000)])
    }

    private func readOnly() async {
        for _ in 0..<20 where env.nowPlaying.item == nil {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let bundleID = env.nowPlaying.item?.sourceBundleIdentifier, let player = Player.forBundle(bundleID),
              let now = read(player) else {
            write(["event": "abort", "reason": "nothing readable is playing"])
            return
        }
        var entry: [String: Any] = ["event": "read-only", "app": bundleID, "shuffle": now.shuffle, "repeat": now.repeatMode]
        if bundleID == "com.apple.Music" {
            // Read only: favouriting can also add the song to your library, which un-favouriting doesn't undo.
            var error: NSDictionary?
            let favorite = NSAppleScript(source: "tell application id \"\(bundleID)\" to return favorited of current track")?
                .executeAndReturnError(&error)
            entry["favorited"] = favorite?.booleanValue ?? false
            entry["favoriteReadable"] = favorite != nil
            if let error { entry["favoriteError"] = error.description }
        }
        // The new raw Apple Event client must read the same thing (read only).
        if let scriptable = ScriptablePlayer(bundleID: bundleID) {
            let started = Date()
            let modes = await AppleEventPlayerControls().modes(of: scriptable)
            entry["appleEvents"] = modes.map { "shuffle \($0.shuffle), repeat \($0.repeatMode), canChange \($0.canChange)" } ?? "nil"
            entry["appleEventsMs"] = Int(Date().timeIntervalSince(started) * 1000)
        }
        write(entry)
    }

    private init(env: AppEnvironment, logURL: URL) {
        self.env = env
        self.logURL = logURL
    }

    /// The two players with a scripting interface, and their AppleScript names for shuffle and repeat.
    private struct Player {
        let bundleID: String
        let read: String
        let setShuffle: (Bool) -> String
        let setRepeat: (String) -> String
        let otherRepeat: (String) -> String

        static func forBundle(_ id: String) -> Player? {
            switch id {
            case "com.spotify.client":
                return Player(bundleID: id,
                              read: "tell application id \"\(id)\" to return {shuffling, repeating as text}",
                              setShuffle: { "tell application id \"\(id)\" to set shuffling to \($0)" },
                              setRepeat: { "tell application id \"\(id)\" to set repeating to \($0)" },
                              otherRepeat: { $0 == "true" ? "false" : "true" })
            case "com.apple.Music":
                return Player(bundleID: id,
                              read: "tell application id \"\(id)\" to return {shuffle enabled, song repeat as text}",
                              setShuffle: { "tell application id \"\(id)\" to set shuffle enabled to \($0)" },
                              setRepeat: { "tell application id \"\(id)\" to set song repeat to \($0)" },
                              otherRepeat: { $0 == "off" ? "all" : "off" })
            default:
                return nil
            }
        }
    }

    private func run() async {
        for _ in 0..<20 where env.nowPlaying.item == nil {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let bundleID = env.nowPlaying.item?.sourceBundleIdentifier else {
            write(["event": "abort", "reason": "nothing is playing"])
            return
        }
        guard let player = Player.forBundle(bundleID) else {
            write(["event": "abort", "reason": "\(bundleID) has no scripting interface (only Spotify and Music do)"])
            return
        }
        write(["event": "start", "app": bundleID])

        // 1. Permission, asked off the main thread so Brim stays responsive while the prompt is up.
        let status = await Task.detached { () -> OSStatus in
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
        }.value
        write(["step": "automation permission", "status": Int(status),
               "meaning": status == noErr ? "allowed" : (status == -1743 ? "denied" : "other")])
        guard status == noErr else { return }

        // 2. Read.
        guard let start = read(player) else { return }
        write(["step": "read", "shuffle": start.shuffle, "repeat": start.repeatMode, "ms": start.ms])
        if bundleID == "com.spotify.client" {
            // Spotify can forbid shuffle / repeat for what's playing; if so, setting them does nothing.
            var error: NSDictionary?
            let allowed = NSAppleScript(source: "tell application id \"\(bundleID)\" to return {shuffling enabled, repeating enabled}")?
                .executeAndReturnError(&error)
            write(["step": "Spotify allows", "shuffle": allowed?.atIndex(1)?.booleanValue ?? false,
                   "repeat": allowed?.atIndex(2)?.booleanValue ?? false, "error": error?.description ?? ""])
        }

        // 3. Change through AppleScript, then restore.
        await change("AppleScript shuffle", player, script: player.setShuffle(!start.shuffle), restore: player.setShuffle(start.shuffle),
                     expectChanged: { $0.shuffle != start.shuffle }, expectRestored: { $0.shuffle == start.shuffle })
        await change("AppleScript repeat", player, script: player.setRepeat(player.otherRepeat(start.repeatMode)),
                     restore: player.setRepeat(start.repeatMode),
                     expectChanged: { $0.repeatMode != start.repeatMode }, expectRestored: { $0.repeatMode == start.repeatMode })

        // 4. The Now Playing route (what play/pause uses today): does the app obey it?
        await env.nowPlayingService.perform(.toggleShuffle)
        try? await Task.sleep(for: .milliseconds(800))
        let afterRouteShuffle = read(player)
        write(["step": "Now Playing route: toggle shuffle", "obeyed": afterRouteShuffle.map { $0.shuffle != start.shuffle } ?? false])
        if let afterRouteShuffle, afterRouteShuffle.shuffle != start.shuffle { _ = runScript(player.setShuffle(start.shuffle)) }
        await env.nowPlayingService.perform(.toggleRepeat)
        try? await Task.sleep(for: .milliseconds(800))
        let afterRouteRepeat = read(player)
        write(["step": "Now Playing route: toggle repeat", "obeyed": afterRouteRepeat.map { $0.repeatMode != start.repeatMode } ?? false,
               "repeatNow": afterRouteRepeat?.repeatMode ?? "?"])
        if let afterRouteRepeat, afterRouteRepeat.repeatMode != start.repeatMode { _ = runScript(player.setRepeat(start.repeatMode)) }
        // Give the player time to apply the restore before checking (run 4 read too early and left repeat on "all").
        for attempt in 1...3 {
            try? await Task.sleep(for: .milliseconds(1200))
            guard let end = read(player) else { break }
            let ok = end.shuffle == start.shuffle && end.repeatMode == start.repeatMode
            write(["step": "player restored", "ok": ok, "attempt": attempt, "shuffle": end.shuffle, "repeat": end.repeatMode])
            if ok { break }
            if end.shuffle != start.shuffle { _ = runScript(player.setShuffle(start.shuffle)) }
            if end.repeatMode != start.repeatMode { _ = runScript(player.setRepeat(start.repeatMode)) }
        }

        // 5. Output picker.
        await switchOutput()
        write(["event": "done"])
    }

    private func change(_ name: String, _ player: Player, script: String, restore: String,
                        expectChanged: (Reading) -> Bool, expectRestored: (Reading) -> Bool) async {
        let setMs = runScript(script)
        try? await Task.sleep(for: .milliseconds(1200))  // run 1 read back after 0.3 s; give the player longer
        let changed = read(player)
        _ = runScript(restore)
        try? await Task.sleep(for: .milliseconds(1200))
        let restored = read(player)
        write(["step": name, "setMs": setMs ?? -1, "changed": changed.map(expectChanged) ?? false,
               "restored": restored.map(expectRestored) ?? false])
    }

    private struct Reading {
        let shuffle: Bool
        let repeatMode: String
        let ms: Int
    }

    private func read(_ player: Player) -> Reading? {
        let started = Date()
        var error: NSDictionary?
        guard let result = NSAppleScript(source: player.read)?.executeAndReturnError(&error),
              let shuffle = result.atIndex(1)?.booleanValue, let repeatValue = result.atIndex(2)?.stringValue else {
            write(["step": "read failed", "error": error?.description ?? "unknown"])
            return nil
        }
        return Reading(shuffle: shuffle, repeatMode: repeatValue, ms: Int(Date().timeIntervalSince(started) * 1000))
    }

    /// Runs a script; returns how long it took in ms, or nil on failure.
    private func runScript(_ source: String) -> Int? {
        let started = Date()
        var error: NSDictionary?
        guard NSAppleScript(source: source)?.executeAndReturnError(&error) != nil else {
            write(["step": "script failed", "script": source, "error": error?.description ?? "unknown"])
            return nil
        }
        return Int(Date().timeIntervalSince(started) * 1000)
    }

    // MARK: - Output picker

    private func switchOutput() async {
        let outputs = Self.outputDevices()
        let current = Self.defaultOutput()
        write(["step": "outputs", "devices": outputs.map(\.name), "current": outputs.first { $0.id == current }?.name ?? "?"])
        guard let other = outputs.first(where: { $0.id != current }) else {
            write(["step": "output switch", "skipped": "only one output device"])
            return
        }
        let started = Date()
        let switched = Self.setDefaultOutput(other.id)
        try? await Task.sleep(for: .milliseconds(1500))
        let nowOther = Self.defaultOutput() == other.id
        let switchedBack = Self.setDefaultOutput(current)
        try? await Task.sleep(for: .milliseconds(500))
        write(["step": "output switch", "to": other.name, "switched": switched && nowOther,
               "back": switchedBack && Self.defaultOutput() == current,
               "totalMs": Int(Date().timeIntervalSince(started) * 1000)])
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func outputDevices() -> [(id: AudioObjectID, name: String)] {
        var address = address(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        return ids.compactMap { id in
            var streams = Self.address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
            var streamSize = UInt32(0)
            AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize)
            guard streamSize > 0 else { return nil }
            var nameAddress = Self.address(kAudioObjectPropertyName)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name)
            return (id, name?.takeRetainedValue() as String? ?? "device \(id)")
        }
    }

    private static func defaultOutput() -> AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    private static func setDefaultOutput(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = device
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioObjectID>.size), &value) == noErr
    }

    func write(_ entry: [String: Any]) {
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

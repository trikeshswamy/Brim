#if DEBUG
import AppKit
import CoreAudio
import EventKit
import IOBluetooth
import os
import BrimCore
import BrimSystem
import BrimFeatures

/// Debug-only tests before building P-4's risky parts (2026-09-30). Never in release builds.
/// - `--airpods-check <log>`: reads left/right/case battery from connected Bluetooth audio devices through
///   IOBluetooth's battery calls (not public API, present on macOS 27 per Gate 2), once, with what Brim can see of each device's name.
/// - `--menu-check <log>`: the pill's right-click menu as built now (nothing is clicked), then again with
///   keep-awake on for 30 min (turned off right after).
/// - `--keep-awake-check`: keep-awake on for 8 s, then off (read `pmset -g assertions` meanwhile).
/// - `--timer-test`: a 100 s timer (1 min left at 40 s, Time's up with sound at 100 s).
/// - `--calendar-preview`: a made-up event whose 5-minute reminder shows 5 s after launch.
/// - `--calendar-check <log>`: whether the Mac's calendar has your events (counts only; asks for access once).
/// - `--bluetooth-thread-check`: replays a connection from a background queue (see below).
/// - `--swipe-check <log>`: logs two-finger swipes near the top of the screen until Brim quits; only the
///   direction, size and place of each swipe is kept.
@MainActor
enum P4Checks {
    static func startIfRequested(environment: AppEnvironment) {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--menu-check"), flag + 1 < args.count {
            // The pill's right-click menu, as built right now (titles, submenu, enabled, checked). Nothing is clicked.
            let log = URL(fileURLWithPath: args[flag + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                func describe(_ menu: NSMenu) -> [[String: Any]] {
                    menu.items.map { item in
                        var entry: [String: Any] = ["title": item.isSeparatorItem ? "—" : item.title, "enabled": item.isEnabled,
                                                    "checked": item.state == .on]
                        if let submenu = item.submenu { entry["submenu"] = describe(submenu) }
                        return entry
                    }
                }
                write(["event": "menu", "items": describe(environment.makePillMenu())], to: log)
                // Keep Mac Awake ▸ while a length runs: when it ends, the lengths, Turn Off (0.13.1).
                guard !environment.keepAwake.isOn else { return }
                environment.keepAwake.start(minutes: 30)
                write(["event": "menu-keep-awake-on", "isOn": environment.keepAwake.isOn,
                       "items": describe(environment.makePillMenu())], to: log)
                environment.keepAwake.stop()
                write(["event": "keep-awake-stopped", "isOn": environment.keepAwake.isOn], to: log)
            }
        }
        if args.contains("--keep-awake-check") {
            // Keep-awake on for 8 s, then off: `pmset -g assertions` shows "Brim: keep awake" meanwhile.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { environment.keepAwake.set(true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { environment.keepAwake.set(false) }
        }
        if args.contains("--timer-test") {
            // A 100-second timer: "1 min left" at 40 s, "Time's up" (with sound) at 100 s.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { environment.timer.start(length: 100) }
        }
        if args.contains("--calendar-preview") {
            // A made-up event starting in 5 min 3 s: the reminder shows in 3 s. Nothing is written anywhere.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { environment.calendar.preview() }
        }
        if let flag = args.firstIndex(of: "--airpods-check"), flag + 1 < args.count {
            airpodsCheck(log: URL(fileURLWithPath: args[flag + 1]))
        }
        if let flag = args.firstIndex(of: "--swipe-check"), flag + 1 < args.count {
            swipeCheck(log: URL(fileURLWithPath: args[flag + 1]))
        }
        if args.contains("--bluetooth-thread-check") { bluetoothThreadCheck() }
        if let flag = args.firstIndex(of: "--music-modes-check"), flag + 1 < args.count {
            musicModesCheck(environment: environment, log: URL(fileURLWithPath: args[flag + 1]))
        }
        if let flag = args.firstIndex(of: "--context-menu-check"), flag + 1 < args.count {
            contextMenuCheck(environment: environment, log: URL(fileURLWithPath: args[flag + 1]))
        }
        if let flag = args.firstIndex(of: "--calendar-check"), flag + 1 < args.count {
            calendarCheck(log: URL(fileURLWithPath: args[flag + 1]))
        }
    }

    /// Item 4, your case: the pointer leaves the open island (its 0.6 s close starts), and 0.45 s later you right-click
    /// it to change something else. The right-click goes through Brim's normal event queue (your pointer doesn't move);
    /// the menu closes with an Escape sent to Brim alone. Then: does the island stay open, and did the menu have all
    /// its items? Add `--no-menu-hold` for the "before" run.
    private static func contextMenuCheck(environment: AppEnvironment, log: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let island = environment.island
            let window = environment.debugIslandWindow
            let began = Date()
            var samples: [String] = []
            let menus = OSAllocatedUnfairLock(initialState: [String]())
            let center = NotificationCenter.default
            let observers = [
                center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                    let titles = (note.object as? NSMenu)?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
                    menus.withLock { $0.append("opened at \(Int(Date().timeIntervalSince(began) * 1000)) ms: \(titles.joined(separator: " | "))") }
                },
                center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { _ in
                    menus.withLock { $0.append("closed at \(Int(Date().timeIntervalSince(began) * 1000)) ms") }
                },
            ]
            @MainActor func sample(_ phase: String) {
                window.debugPointerCheck()  // what a pointer move does (your pointer is away from the island)
                samples.append("\(phase) \(Int(Date().timeIntervalSince(began) * 1000)) ms: \(island.surface.isExpanded ? "open" : "closed")")
            }
            island.open(page: .music)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { sample("pointer left, close starts") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                let panel = window.debugPanel
                let point = NSPoint(x: panel.frame.width / 2 + 60, y: panel.frame.height - 60)  // over the open island
                guard let click = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 1) else { return }
                NSApp.postEvent(click, atStart: false)
            }
            // The menu's close: Escape to Brim alone at 3 s, from another thread (the menu blocks Brim's main thread).
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.postToPid(getpid()) }
            }
            for at in [3.1, 3.8, 4.4, 5.0, 5.7] {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { sample("after the menu") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                observers.forEach(center.removeObserver)
                write(["event": "result", "samples": samples, "menus": menus.withLock { $0 }], to: log)
            }
        }
    }

    /// Your fix round 2 (item 9, 2026-09-30): how Music answers the shuffle and repeat buttons, through the same Apple
    /// Events they send. Flips each, reads back at 0 / 100 / 250 / 500 / 1000 / 2000 ms to time when Music reports the
    /// change, then puts both back. Changes Music's shuffle and repeat for about 20 s (shuffle can reorder Up Next).
    private static func musicModesCheck(environment: AppEnvironment, log: URL) {
        Task {
            let controls = AppleEventPlayerControls()
            guard let start = await controls.modes(of: .music) else {
                write(["event": "abort", "reason": "Music isn't running or didn't answer"], to: log)
                return
            }
            for _ in 0..<10 where environment.nowPlaying.item == nil { try? await Task.sleep(for: .milliseconds(500)) }
            var error: NSDictionary?
            let playerState = NSAppleScript(source: "tell application id \"com.apple.Music\" to return player state as text")?
                .executeAndReturnError(&error).stringValue ?? "?"
            let nowPlayingApp = environment.nowPlaying.item?.sourceBundleIdentifier ?? "none"
            write(["event": "start", "shuffle": start.shuffle, "repeat": "\(start.repeatMode)", "musicState": playerState,
                   "nowPlayingApp": nowPlayingApp, "source": "\(environment.nowPlaying.source)"], to: log)
            @MainActor func trace(_ name: String, set: () async -> Bool, matches: (PlayerModes) -> Bool) async {
                let began = Date()
                let ok = await set()
                let setMs = Int(Date().timeIntervalSince(began) * 1000)
                var reads: [[String: Any]] = []
                for at in [0.0, 0.1, 0.25, 0.5, 1.0, 2.0] {
                    let wait = at - Date().timeIntervalSince(began)
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    let now = await controls.modes(of: .music)
                    reads.append(["ms": Int(Date().timeIntervalSince(began) * 1000), "matches": now.map(matches) ?? false,
                                  "shuffle": now?.shuffle ?? false, "repeat": now.map { "\($0.repeatMode)" } ?? "nil"])
                }
                write(["event": name, "setOK": ok, "setMs": setMs, "reads": reads], to: log)
            }
            await trace("shuffle \(!start.shuffle)", set: { await controls.setShuffle(!start.shuffle, in: .music) },
                        matches: { $0.shuffle == !start.shuffle })
            await trace("shuffle back", set: { await controls.setShuffle(start.shuffle, in: .music) },
                        matches: { $0.shuffle == start.shuffle })
            for mode in [RepeatMode.all, .one, .off] {
                await trace("repeat \(mode)", set: { await controls.setRepeat(mode, in: .music) }, matches: { $0.repeatMode == mode })
            }
            await trace("repeat back", set: { await controls.setRepeat(start.repeatMode, in: .music) },
                        matches: { $0.repeatMode == start.repeatMode })
            // macOS's Now Playing route, what Control Center uses, setting a value (never toggling). It reaches only the
            // Now Playing app, so only when that's Music (it would change another player's shuffle otherwise).
            let route = environment.nowPlayingService
            if nowPlayingApp == "com.apple.Music", playerState == "playing" {
                await trace("NP shuffle \(!start.shuffle)", set: { await route.setShuffle(!start.shuffle); return true },
                            matches: { $0.shuffle == !start.shuffle })
                await trace("NP shuffle back", set: { await route.setShuffle(start.shuffle); return true },
                            matches: { $0.shuffle == start.shuffle })
                await trace("NP repeat all", set: { await route.setRepeat(.all); return true }, matches: { $0.repeatMode == .all })
                await trace("NP repeat back", set: { await route.setRepeat(start.repeatMode); return true },
                            matches: { $0.repeatMode == start.repeatMode })
            } else {
                write(["event": "skipped Now Playing route", "why": "Music isn't the Now Playing app, or isn't playing"], to: log)
            }
            // Brim's own buttons (both routes and the confirmation): what each button shows next to Music's real state.
            let buttons = environment.playerModes
            buttons.refresh()
            for _ in 0..<20 where buttons.modes == nil { try? await Task.sleep(for: .milliseconds(100)) }
            @MainActor func press(_ name: String, _ action: () -> Void) async {
                let began = Date()
                action()
                var seen: [String] = []
                for at in [0.1, 0.3, 0.6, 1.2, 2.5] {
                    let wait = at - Date().timeIntervalSince(began)
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    let truth = await controls.modes(of: .music)
                    let shown = buttons.modes
                    seen.append("\(Int(Date().timeIntervalSince(began) * 1000)) ms: button \(shown.map { "\($0.shuffle)/\($0.repeatMode)" } ?? "none"), Music \(truth.map { "\($0.shuffle)/\($0.repeatMode)" } ?? "?")")
                }
                write(["event": "button \(name)", "seen": seen], to: log)
            }
            if buttons.player == .music {
                await press("shuffle", buttons.toggleShuffle)
                await press("shuffle again", buttons.toggleShuffle)
                for step in 1...3 { await press("repeat \(step)", buttons.cycleRepeat) }
            } else {
                write(["event": "skipped buttons", "why": "Brim's buttons point at \(buttons.player?.rawValue ?? "nothing")"], to: log)
            }
            // Put back anything still changed, both ways.
            if let now = await controls.modes(of: .music), !now.matches(start) {
                _ = await controls.setShuffle(start.shuffle, in: .music)
                _ = await controls.setRepeat(start.repeatMode, in: .music)
                if nowPlayingApp == "com.apple.Music" {
                    await route.setShuffle(start.shuffle)
                    await route.setRepeat(start.repeatMode)
                }
                try? await Task.sleep(for: .seconds(2))
            }
            let end = await controls.modes(of: .music)
            write(["event": "done", "restored": end.map { $0.shuffle == start.shuffle && $0.repeatMode == start.repeatMode } ?? false],
                  to: log)
        }
    }

    /// Does macOS's calendar database have your events at all (before building F8)? Asks for Calendar
    /// access once, then logs only counts: calendars per account type, and events in the next 7 days
    /// (today, timed, all-day, declined, with a Zoom/Meet/Teams/FaceTime link). No titles, no times.
    private static var calendarStore: EKEventStore?

    private static func calendarCheck(log: URL) {
        let store = EKEventStore()
        calendarStore = store
        nonisolated(unsafe) let unsafeStore = store
        store.requestFullAccessToEvents { granted, error in
            DispatchQueue.main.async {
                write(["event": "access", "granted": granted, "error": error.map { String(describing: $0) } ?? ""], to: log)
                guard granted else { return }
                let calendars = unsafeStore.calendars(for: .event)
                var byAccount: [String: Int] = [:]
                for calendar in calendars { byAccount[accountKind(calendar.source), default: 0] += 1 }
                write(["event": "calendars", "count": calendars.count, "byAccount": byAccount], to: log)
                let now = Date()
                let week = now.addingTimeInterval(7 * 24 * 3600)
                let events = unsafeStore.events(matching: unsafeStore.predicateForEvents(withStart: now, end: week, calendars: nil))
                let declined = events.filter { $0.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined }
                write(["event": "events", "next7Days": events.count,
                       "today": events.filter { Calendar.current.isDateInToday($0.startDate) }.count,
                       "timed": events.filter { !$0.isAllDay }.count, "allDay": events.filter(\.isAllDay).count,
                       "declined": declined.count, "withMeetingLink": events.filter(hasMeetingLink).count,
                       "nextStartsInMinutes": events.filter { !$0.isAllDay && $0.startDate > now }
                           .map { Int($0.startDate.timeIntervalSince(now) / 60) }.min() ?? -1], to: log)
                write(["event": "done"], to: log)
            }
        }
    }

    private static func accountKind(_ source: EKSource?) -> String {
        switch source?.sourceType {
        case .local?: "on this Mac"
        case .exchange?: "Exchange"
        case .calDAV?: source?.title.localizedCaseInsensitiveContains("icloud") == true ? "iCloud" : "CalDAV (Google, others)"
        case .mobileMe?: "iCloud (old)"
        case .subscribed?: "subscribed"
        case .birthdays?: "birthdays"
        default: "other"
        }
    }

    private static func hasMeetingLink(_ event: EKEvent) -> Bool {
        let text = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: " ").lowercased()
        return ["zoom.us/", "meet.google.com/", "teams.microsoft.com/", "teams.live.com/", "facetime.apple.com/"]
            .contains { text.contains($0) }
    }

    /// Replays each connected device's connection the way macOS 27 delivers new ones: from a background queue
    /// (that crashed Brim on 2026-09-30). A separate, unstarted service takes it, so no notice shows. Passed
    /// when the "devices" log says "Connected: sound device, at start: false", then "Battery after 2 s", and
    /// Brim is still running.
    private static var threadCheckService: BluetoothHeadphonesService?

    private static func bluetoothThreadCheck() {
        let service = BluetoothHeadphonesService()
        threadCheckService = service
        let devices = ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []).filter { $0.isConnected() }
        for device in devices {
            nonisolated(unsafe) let device = device
            DispatchQueue.global().async {
                _ = service.perform(NSSelectorFromString("connected:device:"), with: nil, with: device)
            }
        }
    }

    /// One reading of each connected device, plus what Brim can see of its name (macOS 27 hid it from a
    /// plain script: an empty name in the sound output list, "\u{2}" from IOBluetooth).
    private static func airpodsCheck(log: URL) {
        let calls = ["batteryPercentLeft", "batteryPercentRight", "batteryPercentCase", "batteryPercentSingle"]
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        for device in devices where device.isConnected() {
            var values: [String: Any] = ["event": "device", "bluetoothName": describe(device.name),
                                         "addressShape": shape(device.addressString),
                                         "classMajor": Int(device.deviceClassMajor)]
            for call in calls + ["productID", "vendorID"] where device.responds(to: NSSelectorFromString(call)) {
                values[call] = device.value(forKey: call) ?? NSNull()
            }
            write(values, to: log)
        }
        for output in bluetoothOutputs() { write(["event": "sound output"].merging(output) { $1 }, to: log) }
        write(["event": "done", "connected": devices.filter { $0.isConnected() }.count], to: log)
    }

    /// A name's length and whether it's usable; its characters only when it's not (they're then not a name).
    private static func describe(_ name: String?) -> String {
        guard let name else { return "nil" }
        if DeviceNames.usable(name) != nil { return "usable, \(name.count) characters" }
        return "unusable: " + name.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " ")
    }

    /// "70-F9-4A-12-34-56" → "XX-XX-XX-XX-XX-XX": only the spelling matters here.
    private static func shape(_ address: String?) -> String {
        String((address ?? "nil").map { $0.isHexDigit ? "X" : $0 })
    }

    private static func bluetoothOutputs() -> [[String: Any]] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        return ids.compactMap { id in
            var transport = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
            var value = UInt32(0)
            var valueSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &transport, 0, nil, &valueSize, &value) == noErr,
                  value == kAudioDeviceTransportTypeBluetooth || value == kAudioDeviceTransportTypeBluetoothLE else { return nil }
            return ["name": describe(string(kAudioObjectPropertyName, of: id)), "uidShape": shape(string(kAudioDevicePropertyDeviceUID, of: id))]
        }
    }

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Two-finger swipes near the top of the screen, until Brim quits. Both listeners: the system-wide one
    /// never hears swipes over Brim's own windows (the pill's hover strip, the open island) — that's why
    /// the first run heard nothing — so a local one listens there.
    private static func swipeCheck(log: URL) {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { event in
            MainActor.assumeIsolated { swipe(event, heardBy: "system-wide", log: log) }
        }) { swipeMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { event in
            MainActor.assumeIsolated { swipe(event, heardBy: "Brim's window", log: log) }
            return event
        }) { swipeMonitors.append(local) }
        write(["event": "listening", "listeners": swipeMonitors.count], to: log)
    }

    private static var swipeMonitors: [Any] = []
    private static var dx: CGFloat = 0
    private static var dy: CGFloat = 0

    private static func swipe(_ event: NSEvent, heardBy listener: String, log: URL) {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main,
              screen.frame.maxY - point.y < 120 else { return }  // the island's part of the screen only
        if event.phase == .began { dx = 0; dy = 0 }
        dx += event.scrollingDeltaX
        dy += event.scrollingDeltaY
        guard event.phase == .ended || event.phase == .cancelled else { return }
        // With natural scrolling the deltas follow the fingers; without it they're reversed (to be confirmed).
        let natural = event.isDirectionInvertedFromDevice
        let fingersX = natural ? dx : -dx, fingersY = natural ? dy : -dy
        let direction = abs(fingersX) > abs(fingersY) ? (fingersX > 0 ? "right" : "left") : (fingersY > 0 ? "down" : "up")
        let area = NSRect(x: screen.frame.midX - 150, y: screen.frame.maxY - 50, width: 300, height: 50)
        write(["event": "swipe", "heardBy": listener, "window": event.window.map { String(describing: type(of: $0)) } ?? "none",
               "fingers": direction, "dx": Int(dx), "dy": Int(dy), "natural": natural, "overPill": area.contains(point),
               "fromTop": Int(screen.frame.maxY - point.y), "fromCentre": Int(point.x - screen.frame.midX)], to: log)
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

import AppKit
import ApplicationServices
import BrimCore

/// The small, privacy-preserving snapshot Brim needs when Safari's web video is absent from MediaRemote.
/// Accessibility is used only after the user grants Brim access; no page text or URL is retained here.
struct SafariAccessibilitySnapshot: Equatable, Sendable {
    let title: String
    let isPlaying: Bool
    let position: TimeInterval?
    let duration: TimeInterval?
    let supportsSeek: Bool

    var nowPlaying: NowPlaying {
        NowPlaying(title: title, artist: "Safari", bundleIdentifier: "com.apple.Safari", isPlaying: isPlaying,
                   duration: duration, elapsed: position, timestamp: .now, playbackRate: 1,
                   mediaType: "kMRMediaRemoteNowPlayingInfoTypeVideo", supportsSeeking: supportsSeek)
    }
}

/// Best-effort Safari fallback. It is intentionally conservative: if Safari does not expose a real playing button,
/// or does not expose a writable progress slider, Brim leaves that capability unavailable instead of simulating clicks.
enum SafariAccessibilityMedia {
    nonisolated struct Controls {
        let playPause: AXUIElement?
        let slider: AXUIElement?
        let isPlaying: Bool
        let title: String
        let position: TimeInterval?
        let duration: TimeInterval?
        let supportsSeek: Bool
    }

    nonisolated static func read() -> SafariAccessibilitySnapshot? {
        // The player found last time, re-read in a few requests; a full look only when it's gone (2026-10-26).
        guard let controls = rememberedControls() ?? controls() else { return nil }
        return SafariAccessibilitySnapshot(title: controls.title, isPlaying: controls.isPlaying, position: controls.position,
                                            duration: controls.duration, supportsSeek: controls.supportsSeek)
    }

    nonisolated static func perform(_ command: MediaCommand) -> Bool {
        // Commands must use the focused Safari window. Scanning every window can find a stale
        // button in one tab and send the action to a different tab than the one being watched.
        guard let controls = focusedRememberedControls() ?? controls(focusedOnly: true) else { return false }
        switch command {
        case .togglePlayPause, .play, .pause:
            guard let playPause = controls.playPause else { return false }
            return AXUIElementPerformAction(playPause, kAXPressAction as CFString) == .success
        case .nextTrack, .previousTrack, .toggleShuffle, .toggleRepeat, .skipBackward15, .skipForward15:
            return false
        }
    }

    /// Sets either a seconds-based HTML range or a normalized 0…1 range. Safari exposes both shapes depending on
    /// the site's player. `duration` comes from the last snapshot, so a normalized slider can still seek correctly.
    nonisolated static func seek(to position: TimeInterval, duration: TimeInterval? = nil) -> Bool {
        // Seeking is especially sensitive to stale AX elements, so use only the focused window
        // and resolve the slider and its duration from that same window.
        guard let controls = focusedRememberedControls() ?? controls(focusedOnly: true), controls.supportsSeek,
              let slider = controls.slider,
              let minValue = number(slider, kAXMinValueAttribute),
              let maxValue = number(slider, kAXMaxValueAttribute) else { return false }
        let range = maxValue - minValue
        let target: Double
        if range <= 1.01, let mediaDuration = duration ?? controls.duration, mediaDuration > 0 {
            target = minValue + (Swift.max(0, position) / mediaDuration) * range
        } else {
            target = minValue + Swift.max(0, position)
        }
        let value = Swift.min(Swift.max(target, minValue), maxValue)
        return AXUIElementSetAttributeValue(slider, kAXValueAttribute as CFString, NSNumber(value: value)) == .success
    }

    nonisolated private static func controls(focusedOnly: Bool = false) -> Controls? {
        guard AXIsProcessTrusted(),
              let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first
        else { return nil }

        let app = AXUIElementCreateApplication(safari.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let roots = rootWindows(of: app, focusedOnly: focusedOnly)
        guard !roots.isEmpty else { return nil }

        // Resolve each window independently. The old merged traversal could pair controls from
        // different windows, which made Private Browsing commands look random.
        for root in roots {
            var queue = [(root, 0)]
            var queueIndex = 0
            var pause: AXUIElement?
            var play: AXUIElement?
            var slider: AXUIElement?
            var timeRange: (position: TimeInterval, duration: TimeInterval)?
            var title: String?
            var timeElement: AXUIElement?
            var nodes = 0

            while queueIndex < queue.count, nodes < 8_000 {
                let (element, depth) = queue[queueIndex]
                queueIndex += 1
                nodes += 1
                // One request to Safari per element, not ~10 (2026-10-26: one Wikipedia page took 6.9 s a scan).
                let node = Node(element)
                let role = node.role
                let lower = node.label.lowercased()

                if title == nil, role == "AXWindow" || role == "AXWebArea" {
                    title = nonEmpty(node.title)
                }
                if role == "AXButton", isEnabled(element), hasPressAction(element) {
                    if pause == nil, isPauseLabel(lower) {
                        pause = element
                    } else if play == nil, isPlayLabel(lower) {
                        play = element
                    }
                }
                if timeRange == nil, let range = node.timeLabels.lazy.compactMap(parseMediaTimeRange).first {
                    timeRange = range
                    timeElement = element
                }
                if role == "AXSlider", slider == nil, isProgressLabel(lower), number(element, kAXValueAttribute) != nil {
                    slider = element
                }
                // The player's controls are all here: the rest of the page can't change the answer.
                if pause != nil || play != nil, slider != nil || timeRange != nil { break }
                if depth < 80 { queue.append(contentsOf: node.children.map { ($0, depth + 1) }) }
            }

            // A Play button alone means the video is paused. Some custom players expose only a live time range while
            // playing, so accept that as a conservative detection signal even when Safari exposes no button.
            guard pause != nil || play != nil || timeRange != nil else { continue }
            let chosenTitle = title.flatMap(nonEmpty) ?? "Safari video"
            remembered.set(Remembered.Player(root: root, playPause: pause ?? play, slider: slider, time: timeElement,
                                             title: chosenTitle))
            return makeControls(pause: pause, play: play, slider: slider, timeRange: timeRange, title: chosenTitle)
        }
        return nil
    }

    /// Position, duration and seeking from what was found (a full look, or the remembered player re-read).
    nonisolated private static func makeControls(pause: AXUIElement?, play: AXUIElement?, slider: AXUIElement?,
                                                 timeRange: (position: TimeInterval, duration: TimeInterval)?,
                                                 title: String) -> Controls {
        let minValue = slider.flatMap { number($0, kAXMinValueAttribute) }
        let maxValue = slider.flatMap { number($0, kAXMaxValueAttribute) }
        let current = slider.flatMap { number($0, kAXValueAttribute) }
        let sliderDuration: TimeInterval? = if let minValue, let maxValue, maxValue - minValue > 1.01 {
            maxValue - minValue
        } else { nil }
        let duration = timeRange?.duration ?? sliderDuration
        let position: TimeInterval?
        if let timeRange {
            position = timeRange.position
        } else if let current, let minValue, let maxValue, let duration {
            let range = maxValue - minValue
            let raw = range <= 1.01 ? (current - minValue) * duration : current - minValue
            position = Swift.min(Swift.max(0, raw), duration)
        } else {
            position = nil
        }
        let supportsSeek = slider.map { isSettable($0, kAXValueAttribute) } ?? false
        return Controls(playPause: pause ?? play, slider: slider, isPlaying: pause != nil || (play == nil && timeRange != nil),
                        title: title, position: position, duration: duration, supportsSeek: supportsSeek)
    }

    /// The player the last full look found, kept so each second's check is a few requests, not a whole page.
    nonisolated private final class Remembered: @unchecked Sendable {  // guarded by `lock`
        struct Player {
            let root: AXUIElement
            let playPause: AXUIElement?
            let slider: AXUIElement?
            let time: AXUIElement?
            let title: String
        }
        private let lock = NSLock()
        private var player: Player?
        func get() -> Player? { lock.withLock { player } }
        func set(_ new: Player?) { lock.withLock { player = new } }
    }
    nonisolated private static let remembered = Remembered()

    /// The remembered player, re-read: its button says Pause or Play, its time and slider are current. Nil (and
    /// forgotten) when its elements are gone: a closed tab, a new page, a different player.
    nonisolated private static func rememberedControls() -> Controls? {
        guard AXIsProcessTrusted(), let player = remembered.get() else { return nil }
        var pause: AXUIElement?
        var play: AXUIElement?
        if let button = player.playPause {
            let node = Node(button)
            let lower = node.label.lowercased()
            if node.role.isEmpty { remembered.set(nil); return nil }  // gone
            if isPauseLabel(lower) { pause = button } else if isPlayLabel(lower) { play = button } else {
                remembered.set(nil); return nil
            }
        }
        let timeRange = player.time.flatMap { Node($0).timeLabels.lazy.compactMap(parseMediaTimeRange).first }
        guard pause != nil || play != nil || timeRange != nil else { remembered.set(nil); return nil }
        let title = nonEmpty(Node(player.root).title) ?? player.title
        return makeControls(pause: pause, play: play, slider: player.slider, timeRange: timeRange, title: title)
    }

    /// Commands act on the focused window only (stale buttons in other tabs): the remembered player is used for them
    /// only when it's in that window.
    nonisolated private static func focusedRememberedControls() -> Controls? {
        guard let player = remembered.get(),
              let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first,
              let focused = element(AXUIElementCreateApplication(safari.processIdentifier), kAXFocusedWindowAttribute),
              CFEqual(focused, player.root) else { return nil }
        return rememberedControls()
    }

    /// One element's attributes, fetched in a single request to Safari.
    nonisolated private struct Node {
        nonisolated(unsafe) static let attributes = [kAXRoleAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute,
                                 kAXIdentifierAttribute, kAXValueDescriptionAttribute, kAXChildrenAttribute] as CFArray
        var role = "", description: String?, title: String?, help: String?, identifier: String?, valueDescription: String?
        var children: [AXUIElement] = []

        init(_ element: AXUIElement) {
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, Self.attributes, AXCopyMultipleAttributeOptions(), &values) == .success,
                  let list = values as? [AnyObject], list.count == 7 else { return }
            role = list[0] as? String ?? ""
            description = list[1] as? String
            title = list[2] as? String
            help = list[3] as? String
            identifier = list[4] as? String
            valueDescription = list[5] as? String
            children = (list[6] as? [AXUIElement]) ?? []
        }

        /// What a button or slider calls itself (what `mediaLabel` used to read one attribute at a time).
        var label: String { [description, title, help, identifier].compactMap { $0 }.joined(separator: " | ") }
        /// Where a "1:23 / 4:56" time shows up.
        var timeLabels: [String] { [valueDescription, description, title, help].compactMap { $0 } }
    }

    /// Built once (it was rebuilt for every label of every element: most of a scan's own time, 2026-10-26).
    nonisolated(unsafe) private static let timePattern = try? NSRegularExpression(
        pattern: #"(?<!\d)(\d{1,2}:)?\d{1,2}:\d{2}\s*(?:/|of)\s*(\d{1,2}:)?\d{1,2}:\d{2}(?!\d)"#, options: [.caseInsensitive])

    nonisolated private static func parseMediaTimeRange(_ value: String) -> (position: TimeInterval, duration: TimeInterval)? {
        guard value.contains(":"),  // most labels have no time at all
              let regex = timePattern,
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range, in: value) else { return nil }
        let text = String(value[range])
        guard let separator = text.range(of: "/") ?? text.range(of: "of", options: .caseInsensitive) else { return nil }
        let positionText = String(text[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let durationText = String(text[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let position = parseClock(positionText), let duration = parseClock(durationText), duration > 0,
              position >= 0, position <= duration else { return nil }
        return (position, duration)
    }

    nonisolated private static func parseClock(_ value: String) -> TimeInterval? {
        let components = value.split(separator: ":").compactMap { Double($0) }
        guard components.count == 2 || components.count == 3 else { return nil }
        if components.count == 2 { return components[0] * 60 + components[1] }
        return components[0] * 3600 + components[1] * 60 + components[2]
    }

    nonisolated private static func rootWindows(of app: AXUIElement, focusedOnly: Bool) -> [AXUIElement] {
        // Safari Private Browsing can expose a focused window that is not the window returned by
        // the normal AXWindows query. Put the focused window first, then inspect every Safari
        // window so a playing private video is not missed.
        let windows = (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        guard let focused = element(app, kAXFocusedWindowAttribute) else { return focusedOnly ? [] : windows }
        if focusedOnly { return [focused] }
        return [focused] + windows.filter { !CFEqual($0, focused) }
    }

    nonisolated private static func isPauseLabel(_ value: String) -> Bool {
        value.split(separator: "|").contains { raw in
            let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return label == "pause" || label.hasPrefix("pause ") || label.hasPrefix("pause(")
                || label.contains("play/pause") || label.contains("play pause") || label.contains("toggle play")
        }
    }

    nonisolated private static func isPlayLabel(_ value: String) -> Bool {
        value.split(separator: "|").contains { raw in
            let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return label == "play" || label.hasPrefix("play ") || label.hasPrefix("play(")
                || label.contains("play video") || label.contains("playback") && !label.contains("pause")
        }
    }

    nonisolated private static func isProgressLabel(_ value: String) -> Bool {
        value.contains("progress") || value.contains("seek") || value.contains("elapsed") || value.contains("time")
    }

    nonisolated private static func isEnabled(_ element: AXUIElement) -> Bool {
        (value(element, kAXEnabledAttribute) as? Bool) ?? false
    }

    nonisolated private static func hasPressAction(_ element: AXUIElement) -> Bool {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success else { return false }
        return (actions as? [String])?.contains(kAXPressAction as String) == true
    }

    nonisolated private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    nonisolated private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let result = value(parent, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    nonisolated private static func number(_ element: AXUIElement, _ attribute: String) -> Double? {
        (value(element, attribute) as? NSNumber)?.doubleValue
    }

    nonisolated private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.caseInsensitiveCompare("Safari") == .orderedSame ? nil : trimmed
    }

    nonisolated private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }
}

#if DEBUG
/// Debug only: how long one Safari scan takes, the scan Brim repeats every second while nothing plays
/// (`--safari-scan-bench`, 2026-10-26).
public enum SafariScanTimings {
    /// Milliseconds per scan, and whether the last one found a video.
    public static func measure(runs: Int) -> (milliseconds: [Double], found: Bool) {
        var times: [Double] = []
        var found = false
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            found = SafariAccessibilityMedia.read() != nil
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return (times, found)
    }
}
#endif

import AppKit
import ApplicationServices
import BrimCore

/// Spotify's own Playback menu, pressed through Accessibility, the permission Brim already holds for the media keys.
///
/// For ⏯ ⏭ ⏮ while Brim talks to Spotify directly (a paused website holds macOS's Now Playing), and for Shuffle & Repeat
/// everywhere: Spotify 1.3.3 answers no Apple Events (2026-10-02), and macOS 27's per-app media commands still reach the
/// elected app (mediaremote-adapter issue #41), so the menu is the route that works. Read on your Mac (2026-10-02):
/// Play/Pause is the menu's first item, Next ⌘→, Previous ⌘←, Shuffle ⌘S and Repeat ⌘R with a checkmark when on.
/// Found by those shortcuts, so Spotify's language doesn't matter. Pressed only when you click.
nonisolated enum SpotifyPlaybackMenu {
    /// True when the item was found, enabled, and pressed.
    static func press(_ command: MediaCommand, pid: pid_t) -> Bool {
        guard let items = playbackItems(pid: pid) else { return false }
        let target: AXUIElement? = switch command {
        case .togglePlayPause: items.first
        case .nextTrack: items.first(where: isNext)
        case .previousTrack: items.first(where: isPrevious)
        default: nil
        }
        guard let target, isEnabled(target) else { return false }
        return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
    }

    /// Shuffle and repeat from the menu's checkmarks (✓ = on); nil if the menu can't be read.
    static func modes(pid: pid_t) -> PlayerModes? {
        guard let items = playbackItems(pid: pid), let shuffle = items.first(where: isShuffle),
              let repeating = items.first(where: isRepeat) else { return nil }
        return PlayerModes.fromSpotifyMenu(shuffleChecked: isChecked(shuffle), repeatChecked: isChecked(repeating),
                                           enabled: isEnabled(shuffle) && isEnabled(repeating),
                                           inFront: NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)
    }

    /// Presses Shuffle if its checkmark isn't already `on`.
    static func setShuffle(_ on: Bool, pid: pid_t) -> Bool {
        guard let item = playbackItems(pid: pid)?.first(where: isShuffle), isEnabled(item) else {
            return false
        }
        return isChecked(item) == on || AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// One press of Spotify's Repeat: one step of off → all → one → off, exactly like its own button. (0.14.4–0.14.5
    /// pressed until the checkmark matched: two presses with a 1.5 s wait from All to off, during which Brim showed Off
    /// and Spotify One, and a second click mixed two sequences: your report, 2026-10-02.)
    static func pressRepeat(pid: pid_t) -> Bool {
        guard let item = playbackItems(pid: pid)?.first(where: isRepeat), isEnabled(item) else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// The Playback menu's items: the menu that holds ⌘→ (Next).
    private static func playbackItems(pid: pid_t) -> [AXUIElement]? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let bar = element(app, kAXMenuBarAttribute) else { return nil }
        for barItem in children(bar) {
            guard let menu = children(barItem).first else { continue }
            let items = children(menu)
            if items.contains(where: isNext) { return items }
        }
        return nil
    }

    /// ⌘→ / ⌘← by their virtual keys (124 / 123; their character is an invisible arrow code, so it isn't compared:
    /// comparing it broke the menu lookup, 2026-10-02), ⌘S / ⌘R by their letters. Modifiers 0 means ⌘ alone.
    private static func isNext(_ item: AXUIElement) -> Bool { key(of: item) == 124 && modifiers(of: item) == 0 }
    private static func isPrevious(_ item: AXUIElement) -> Bool { key(of: item) == 123 && modifiers(of: item) == 0 }
    private static func isShuffle(_ item: AXUIElement) -> Bool { character(of: item) == "S" && modifiers(of: item) == 0 }
    private static func isRepeat(_ item: AXUIElement) -> Bool { character(of: item) == "R" && modifiers(of: item) == 0 }

    private static func key(of item: AXUIElement) -> Int? {
        (value(item, kAXMenuItemCmdVirtualKeyAttribute) as? NSNumber)?.intValue
    }

    private static func modifiers(of item: AXUIElement) -> Int? {
        (value(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue
    }

    private static func character(of item: AXUIElement) -> String? {
        (value(item, kAXMenuItemCmdCharAttribute) as? String)?.uppercased()
    }

    private static func isChecked(_ item: AXUIElement) -> Bool {
        !((value(item, kAXMenuItemMarkCharAttribute) as? String) ?? "").isEmpty
    }

    private static func isEnabled(_ item: AXUIElement) -> Bool {
        (value(item, kAXEnabledAttribute) as? Bool) ?? false
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let found = value(parent, attribute), CFGetTypeID(found) == AXUIElementGetTypeID() else { return nil }
        return (found as! AXUIElement)
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}

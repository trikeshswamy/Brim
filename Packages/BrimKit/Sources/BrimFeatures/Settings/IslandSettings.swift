import Foundation
import Observation
import BrimCore

/// Island and HUD preferences. Saved in UserDefaults; every change applies instantly.
@Observable
public final class IslandSettings {
    /// Keep music on screen while playing (and for 1 minute after pausing).
    public var keepPillVisible: Bool { didSet { defaults.set(keepPillVisible, forKey: Key.keepPill) } }
    /// When nothing plays: Brim asleep in a small pill (the default), the slim line, or hidden (2026-11-11).
    public var idleStyle: IdleStyle { didSet { defaults.set(idleStyle.rawValue, forKey: Key.idleStyle) } }
    /// One-time tips under the open island (2026-11-11).
    public var tipsEnabled: Bool { didSet { defaults.set(tipsEnabled, forKey: Key.tipsEnabled) } }
    /// The tips you've already seen (`Tip` raw values). Emptied by "Show Tips Again".
    public var tipsSeen: [String] { didSet { defaults.set(tipsSeen, forKey: Key.tipsSeen) } }
    /// How kept music shows: the full pill, or a slim line that covers no toolbar (default: pill).
    public var keptStyle: KeptStyle { didSet { defaults.set(keptStyle.rawValue, forKey: Key.keptStyle) } }
    /// Your Spotify app's Client ID (developer.spotify.com), for Shuffle & Repeat from anywhere. Not a secret.
    public var spotifyClientID: String { didSet { defaults.set(spotifyClientID, forKey: SpotifyWeb.clientIDKey) } }
    /// Over a full-screen app: hide (nothing rests, only important notices; default, your pick 2026-10-02) or rest as
    /// the slim line (0.14.3).
    public var fullScreen: FullScreenIsland { didSet { defaults.set(fullScreen.rawValue, forKey: Key.fullScreen) } }
    /// Liquid Glass, or a black notch hanging from the top edge (default: Liquid Glass).
    public var appearance: IslandAppearance { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) } }
    /// Ways to open the island from the top edge. At least one stays on.
    public var openOnRest: Bool { didSet { defaults.set(openOnRest, forKey: Key.openOnRest) } }
    public var openOnPush: Bool { didSet { defaults.set(openOnPush, forKey: Key.openOnPush) } }
    public var openOnClick: Bool { didSet { defaults.set(openOnClick, forKey: Key.openOnClick) } }
    public var hudStyle: HUDStyle { didSet { defaults.set(hudStyle.rawValue, forKey: Key.hudStyle) } }
    /// Brim handles the volume and brightness keys, so only Brim's HUD shows (needs the permission).
    public var brimHUDOnly: Bool { didSet { defaults.set(brimHUDOnly, forKey: Key.brimHUDOnly) } }
    /// Synced lyrics from LRCLIB (the only network use: title, artist, album, length).
    public var lyricsEnabled: Bool { didSet { defaults.set(lyricsEnabled, forKey: Key.lyricsEnabled) } }
    /// The open island shows lyrics instead of the title (the quote button). Remembered; off at first.
    public var lyricsModeOn: Bool { didSet { defaults.set(lyricsModeOn, forKey: Key.lyricsModeOn) } }
    /// The full-screen player shows lyrics (its bottom-right switch). Remembered; on at first.
    public var fullScreenLyrics: Bool { didSet { defaults.set(fullScreenLyrics, forKey: Key.fullScreenLyrics) } }
    /// The full-screen player shows the queue on the right instead of lyrics (its bottom-right list switch, 2026-10-29).
    public var fullScreenQueue: Bool { didSet { defaults.set(fullScreenQueue, forKey: Key.fullScreenQueue) } }
    /// The current line lights up word by word (estimated sweep, prototype) or all at once (default for
    /// judging: the sweep, your pick 2026-09-30; the whole line stays as the backup).
    public var lyricsSweep: Bool { didSet { defaults.set(lyricsSweep, forKey: Key.lyricsSweep) } }
    /// ⌥⌘, opens Brim's Settings from any app (your ask, 2026-11-17). ⌘, alone stays each app's own Settings.
    public var settingsShortcut: Bool { didSet { defaults.set(settingsShortcut, forKey: Key.settingsShortcut) } }
    /// Set by the app: macOS refused ⌥⌘, because another app already uses it.
    public var settingsShortcutTaken = false
    /// The two buttons beside the play controls (C1): Shuffle & Repeat, or Favorite & Output.
    public var sideButtons: SideButtons { didSet { defaults.set(sideButtons.rawValue, forKey: Key.sideButtons) } }
    /// Settings → Notices → Battery: plugging in, fully charged, Low Power Mode (P-4). On at first.
    public var batteryNotices: Bool { didSet { defaults.set(batteryNotices, forKey: Key.batteryNotices) } }
    /// Settings → Notices → AirPods and headphones: their battery when they connect (P-4). On at first.
    public var headphonesNotices: Bool { didSet { defaults.set(headphonesNotices, forKey: Key.headphonesNotices) } }
    /// Settings → Calendar → Show your next event (F8). On at first only if Calendar access was already given,
    /// so a first launch never surprises you with a prompt (PRD F8: asked when you turn it on).
    public var calendarEnabled: Bool { didSet { defaults.set(calendarEnabled, forKey: Key.calendarEnabled) } }
    /// Settings → Calendar → Remind me 5 minutes before. On at first.
    public var calendarReminders: Bool { didSet { defaults.set(calendarReminders, forKey: Key.calendarReminders) } }
    /// Settings → Calendar → the calendars you switched off (their identifiers). All on at first.
    public var hiddenCalendars: Set<String> { didSet { defaults.set(Array(hiddenCalendars).sorted(), forKey: Key.hiddenCalendars) } }

    @ObservationIgnored private let defaults: UserDefaults

    /// `headphonesOnAtFirst`: AirPods notices start on only if Bluetooth is already allowed, so a new Mac is never
    /// asked for Bluetooth at launch; turning them on asks (PRD F7, 2026-10-01). Like the calendar.
    public init(defaults: UserDefaults = .standard, calendarOnAtFirst: Bool = false, headphonesOnAtFirst: Bool = false) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.version: 1,
            Key.keepPill: true,
            Key.idleStyle: IdleStyle.asleep.rawValue,
            Key.tipsEnabled: true,
            Key.keptStyle: KeptStyle.pill.rawValue,
            Key.fullScreen: FullScreenIsland.hide.rawValue,
            Key.appearance: IslandAppearance.liquidGlass.rawValue,
            Key.openOnRest: true,
            Key.openOnPush: true,
            Key.openOnClick: true,
            Key.hudStyle: HUDStyle.standard.rawValue,
            Key.brimHUDOnly: true,
            Key.lyricsEnabled: true,
            Key.lyricsModeOn: false,
            Key.fullScreenLyrics: true,
            Key.fullScreenQueue: false,
            Key.lyricsSweep: true,
            Key.settingsShortcut: true,
            Key.sideButtons: SideButtons.shuffleRepeat.rawValue,
            Key.batteryNotices: true,
            Key.headphonesNotices: headphonesOnAtFirst,
            Key.calendarEnabled: calendarOnAtFirst,
            Key.calendarReminders: true,
        ])
        keepPillVisible = defaults.bool(forKey: Key.keepPill)
        idleStyle = IdleStyle(rawValue: defaults.string(forKey: Key.idleStyle) ?? "") ?? .asleep
        tipsEnabled = defaults.bool(forKey: Key.tipsEnabled)
        tipsSeen = defaults.stringArray(forKey: Key.tipsSeen) ?? []
        keptStyle = KeptStyle(rawValue: defaults.string(forKey: Key.keptStyle) ?? "") ?? .pill
        fullScreen = FullScreenIsland(rawValue: defaults.string(forKey: Key.fullScreen) ?? "") ?? .hide
        spotifyClientID = defaults.string(forKey: SpotifyWeb.clientIDKey) ?? ""
        appearance = IslandAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .liquidGlass
        openOnRest = defaults.bool(forKey: Key.openOnRest)
        openOnPush = defaults.bool(forKey: Key.openOnPush)
        openOnClick = defaults.bool(forKey: Key.openOnClick)
        hudStyle = HUDStyle(rawValue: defaults.string(forKey: Key.hudStyle) ?? "") ?? .standard
        brimHUDOnly = defaults.bool(forKey: Key.brimHUDOnly)
        lyricsEnabled = defaults.bool(forKey: Key.lyricsEnabled)
        lyricsModeOn = defaults.bool(forKey: Key.lyricsModeOn)
        fullScreenLyrics = defaults.bool(forKey: Key.fullScreenLyrics)
        fullScreenQueue = defaults.bool(forKey: Key.fullScreenQueue)
        lyricsSweep = defaults.bool(forKey: Key.lyricsSweep)
        settingsShortcut = defaults.bool(forKey: Key.settingsShortcut)
        sideButtons = SideButtons(rawValue: defaults.string(forKey: Key.sideButtons) ?? "") ?? .shuffleRepeat
        batteryNotices = defaults.bool(forKey: Key.batteryNotices)
        headphonesNotices = defaults.bool(forKey: Key.headphonesNotices)
        calendarEnabled = defaults.bool(forKey: Key.calendarEnabled)
        calendarReminders = defaults.bool(forKey: Key.calendarReminders)
        hiddenCalendars = Set(defaults.stringArray(forKey: Key.hiddenCalendars) ?? [])
    }

    /// How many ways to open the island are on. The last one can't be switched off.
    public var enabledOpenTriggers: Int {
        [openOnRest, openOnPush, openOnClick].filter { $0 }.count
    }

    /// Keys are versioned (`settings.version`) so later releases can migrate old values.
    private enum Key {
        static let version = "settings.version"
        static let keepPill = "island.keepPillVisible"
        static let idleStyle = "island.idleStyle"
        static let tipsEnabled = "tips.enabled"
        static let tipsSeen = "tips.seen"
        static let keptStyle = "island.keptStyle"
        static let fullScreen = "island.fullScreen"
        static let appearance = "island.appearance"
        static let openOnRest = "island.open.rest"
        static let openOnPush = "island.open.push"
        static let openOnClick = "island.open.click"
        static let hudStyle = "hud.style"
        static let brimHUDOnly = "hud.brimOnly"
        static let lyricsEnabled = "lyrics.enabled"
        static let lyricsModeOn = "lyrics.islandMode"
        static let fullScreenLyrics = "lyrics.fullScreen"
        static let fullScreenQueue = "queue.fullScreen"
        static let lyricsSweep = "lyrics.sweep"
        static let settingsShortcut = "shortcut.settings"
        static let sideButtons = "controls.sideButtons"
        static let batteryNotices = "notices.battery"
        static let headphonesNotices = "notices.headphones"
        static let calendarEnabled = "calendar.enabled"
        static let calendarReminders = "calendar.reminders"
        static let hiddenCalendars = "calendar.hidden"
    }
}

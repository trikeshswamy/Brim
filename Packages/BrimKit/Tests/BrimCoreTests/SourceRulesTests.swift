import Foundation
import Testing
@testable import BrimCore

struct SourceRulesTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func video(playing: Bool) -> NowPlaying {
        NowPlaying(title: "A site is playing media", bundleIdentifier: "company.thebrowser.dia", isPlaying: playing)
    }
    private func spotify(_ state: PlayerAnnouncement.State, at seconds: Double = 0) -> PlayerAnnouncement {
        PlayerAnnouncement(player: .spotify, state: state, title: "maybe i was wrong about you", artist: "Nora Vale",
                           date: t0.addingTimeInterval(seconds))
    }

    @Test func thePlayingNowPlayingAppWins() {
        #expect(SourceRules.preferred(system: video(playing: true), players: [spotify(.playing)], current: .system) == .system)
    }

    @Test func aPausedVideoGivesWayToSpotifyPlaying() {
        #expect(SourceRules.preferred(system: video(playing: false), players: [spotify(.playing)], current: .system) == .player(.spotify))
    }

    @Test func pausingSpotifyKeepsItOnScreen() {
        // Both paused: don't jump back to the old video.
        #expect(SourceRules.preferred(system: video(playing: false), players: [spotify(.paused)], current: .player(.spotify)) == .player(.spotify))
    }

    @Test func spotifyBeingNowPlayingItselfNeedsNoSwitch() {
        let spotifyItem = NowPlaying(title: "x", bundleIdentifier: "com.spotify.client", isPlaying: false)
        #expect(SourceRules.preferred(system: spotifyItem, players: [spotify(.playing)], current: .system) == .system)
    }

    @Test func aQuitPlayerIsNeverShown() {
        #expect(SourceRules.preferred(system: video(playing: false), players: [spotify(.stopped)], current: .player(.spotify)) == .system)
    }

    @Test func theMostRecentlyStartedPlayerWins() {
        let music = PlayerAnnouncement(player: .music, state: .playing, title: "Song", date: t0.addingTimeInterval(5))
        #expect(SourceRules.preferred(system: video(playing: false), players: [spotify(.playing), music], current: .system) == .player(.music))
    }

    @Test func nothingInNowPlayingMeansNothingToReplace() {
        #expect(SourceRules.preferred(system: nil, players: [spotify(.playing)], current: .system) == .system)
    }
}

struct PlayerAnnouncementTests {
    /// What Spotify 1.3.0 posted on your Mac (2026-09-30), trimmed.
    @Test func readsSpotifysAnnouncement() throws {
        let info: [AnyHashable: Any] = ["Player State": "Paused", "Name": "maybe i was wrong about you", "Artist": "Nora Vale",
                                        "Album": "petal", "Duration": NSNumber(value: 197949), "Playback Position": NSNumber(value: 46.581),
                                        "Track ID": "spotify:track:3iy2QuCtCzpWnR6tia39AB", "Has Artwork": NSNumber(value: true)]
        let date = Date()
        let announcement = try #require(PlayerAnnouncement.parse(player: .spotify, userInfo: info, at: date))
        #expect(announcement.state == .paused)
        #expect(abs((announcement.duration ?? 0) - 197.949) < 0.001)
        #expect(announcement.position == 46.581)
        #expect(announcement.trackID == "spotify:track:3iy2QuCtCzpWnR6tia39AB")   // for its cover (0.17.3)
        let item = try #require(announcement.nowPlaying(artwork: nil))
        #expect(item.bundleIdentifier == "com.spotify.client" && !item.isPlaying && item.title == "maybe i was wrong about you")
    }

    @Test func readsMusicsTotalTime() throws {
        let info: [AnyHashable: Any] = ["Player State": "Playing", "Name": "Song", "Artist": "Artist", "Total Time": NSNumber(value: 200_000)]
        let announcement = try #require(PlayerAnnouncement.parse(player: .music, userInfo: info, at: .now))
        #expect(announcement.duration == 200)
        #expect(announcement.position == nil)
    }

    @Test func unknownStateIsIgnored() {
        #expect(PlayerAnnouncement.parse(player: .spotify, userInfo: ["Name": "x"], at: .now) == nil)
    }
}

/// Spotify's Playback menu: ✓ = on; one Repeat item, so repeat reads as on or off (2026-10-02).
struct SpotifyMenuModesTests {
    @Test func checkmarksAreTheModes() {
        #expect(PlayerModes.fromSpotifyMenu(shuffleChecked: true, repeatChecked: false, enabled: true, inFront: true)
            == PlayerModes(shuffle: true, repeatMode: .off, repeatOnMayBeOne: true))
        #expect(PlayerModes.fromSpotifyMenu(shuffleChecked: false, repeatChecked: true, enabled: false, inFront: true)
            == PlayerModes(shuffle: false, repeatMode: .all, canChange: false, repeatOnMayBeOne: true))  // a locked queue
    }

    /// Measured 2026-10-02: Spotify enables the items only while it's in front; in the background that's the reason.
    @Test func inTheBackgroundTheReasonIsSpotifysRule() {
        let background = PlayerModes.fromSpotifyMenu(shuffleChecked: true, repeatChecked: false, enabled: false, inFront: false)
        #expect(background.changeableOnlyInFront && !background.canChange)
        #expect(background.matches(PlayerModes(shuffle: true, repeatMode: .off)))  // the state still reads right
        #expect(SideSlot.spotifyOnlyInFrontReason.contains("only while it's in front"))
    }
}

/// Spotify 1.3.3 answered no Apple Events (2026-10-02): 35 taps on Next queued, each waiting its 2 s.
struct PlayerReachabilityTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func aTimeoutMakesTheNextEventsFailAtOnceForAMoment() {
        var reach = PlayerReachability()
        #expect(reach.allows(.spotify, at: t0))
        reach.timedOut(.spotify, at: t0)
        #expect(!reach.allows(.spotify, at: t0.addingTimeInterval(4.9)))  // queued taps: skipped at once
        #expect(reach.allows(.music, at: t0))                               // the other player is unaffected
        #expect(reach.allows(.spotify, at: t0.addingTimeInterval(5)))      // then one tries again
        reach.timedOut(.spotify, at: t0)
        reach.answered(.spotify)
        #expect(reach.allows(.spotify, at: t0))                             // any answer clears it
    }
}

struct SideSlotTests {
    /// Your pick (2026-10-05): a sideways swipe on the controls row switches to the other pair, and back.
    @Test func theOtherPair() {
        #expect(SideButtons.shuffleRepeat.other == .favoriteOutput)
        #expect(SideButtons.favoriteOutput.other == .shuffleRepeat)
        #expect(SideButtons.allCases.allSatisfy { $0.other.other == $0 })   // two swipes: back where you started
    }

    private let modes = PlayerModes(shuffle: false, repeatMode: .off)

    @Test func shuffleAndRepeatNeedAScriptablePlayer() {
        #expect(SideSlot.slots(buttons: .shuffleRepeat, modes: modes, player: .spotify, skipButtons: false) == (.shuffle, .repeat))
        #expect(SideSlot.slots(buttons: .shuffleRepeat, modes: nil, player: nil, skipButtons: false) == (nil, nil))
    }

    /// Your report (2026-10-02): with Spotify 1.3.3 not answering Brim, Shuffle & Repeat vanished. Now they stay, faded.
    @Test func shuffleAndRepeatStayWhenThePlayerDoesntAnswer() {
        #expect(SideSlot.slots(buttons: .shuffleRepeat, modes: nil, player: .spotify, skipButtons: false, unreachable: true)
            == (.shuffle, .repeat))
        #expect(SideSlot.slots(buttons: .shuffleRepeat, modes: nil, player: nil, skipButtons: false, unreachable: true)
            == (nil, nil))  // a website: never had them
        #expect(SideSlot.slots(buttons: .shuffleRepeat, modes: nil, player: .spotify, skipButtons: true, unreachable: true)
            == (nil, nil))  // a podcast: neither
        #expect(SideSlot.unreachableReason(player: .spotify) == "Brim can't reach Spotify right now. Spotify's own controls still work.")
        #expect(SideSlot.favoriteUnavailableReason(player: .music, unreachable: true).contains("can't reach Music"))
    }

    /// Your report, 2026-09-30: with Spotify, Shuffle showed where you chose ★.
    @Test func theStarAlwaysShowsForSongs() {
        let music = PlayerModes(shuffle: false, repeatMode: .off, favorite: false)
        #expect(SideSlot.slots(buttons: .favoriteOutput, modes: music, player: .music, skipButtons: false) == (.favorite, .output))
        #expect(SideSlot.slots(buttons: .favoriteOutput, modes: modes, player: .spotify, skipButtons: false) == (.favorite, .output))
        #expect(SideSlot.slots(buttons: .favoriteOutput, modes: nil, player: nil, skipButtons: false) == (.favorite, .output))
    }

    /// 0.18.3: ★ in Music, and in Spotify through its Web API (your Liked Songs).
    @Test func theStarWorksWhereThePlayerSaysWhetherItsAFavorite() {
        let known = PlayerModes(shuffle: false, repeatMode: .off, favorite: true)
        #expect(SideSlot.canFavorite(modes: known, player: .music))
        #expect(SideSlot.canFavorite(modes: known, player: .spotify))
        #expect(!SideSlot.canFavorite(modes: modes, player: .music))        // a song Music can't favorite
        #expect(!SideSlot.canFavorite(modes: modes, player: .spotify))      // not connected, a local file, an ad…
        #expect(!SideSlot.canFavorite(modes: known, player: nil))           // a website
        #expect(!SideSlot.canFavorite(modes: nil, player: nil))
    }

    /// Hovering a faded ★ says what to do.
    @Test func aFadedStarSaysWhy() {
        #expect(SideSlot.favoriteUnavailableReason(player: .spotify).contains("Settings → Media & Lyrics"))
        let reconnect = SideSlot.favoriteUnavailableReason(player: .spotify, needsReconnect: true)
        #expect(reconnect.contains("Disconnect, then Connect"))            // connected before 0.18.3
        #expect(SideSlot.favoriteUnavailableReason(player: .spotify, unreachable: true, needsReconnect: true)
            == SideSlot.unreachableReason(player: .spotify))
        #expect(SideSlot.favoriteUnavailableReason(player: .music) == "Music can't favorite this song.")
        #expect(SideSlot.favoriteUnavailableReason(player: nil) == "★ works with Apple Music and Spotify.")
    }

    @Test func theOutputButtonWorksForVideosToo() {
        #expect(SideSlot.slots(buttons: .favoriteOutput, modes: nil, player: nil, skipButtons: true) == (nil, .output))
    }
}

struct AudioOutputTests {
    @Test func kindsAndSymbolsLikeTheIPhone() {
        #expect(AudioOutput.kind(transport: "bltn", name: "MacBook Air Speakers") == .builtInSpeakers)
        #expect(AudioOutput.kind(transport: "bltn", name: "External Headphones") == .headphones)
        #expect(AudioOutput.kind(transport: "blue", name: "Sam’s AirPods Pro") == .airPods)
        #expect(AudioOutput(id: 2, name: "Sam’s AirPods Pro", kind: .airPods).symbolName == "airpodspro")
        #expect(AudioOutput.kind(transport: "hdmi", name: "LG TV") == .display)
        #expect(AudioOutput.kind(transport: "airp", name: "Living Room") == .airPlay)
    }
}

struct BatteryTests {
    private func state(_ power: BatteryState.Power, _ level: Double = 0.9, lpm: Bool = false) -> BatteryState {
        BatteryState(level: level, power: power, lowPowerMode: lpm)
    }

    @Test func readsIOKitsKeys() {
        // Your Mac on 2026-09-30: AC, 90%, not charging, not full (macOS holding the charge).
        #expect(BatteryState.from(state: "AC Power", isCharging: false, isCharged: false, current: 90, max: 100,
                                  lowPowerMode: false) == state(.notCharging))
        #expect(BatteryState.from(state: "Battery Power", isCharging: false, isCharged: false, current: 50, max: 100,
                                  lowPowerMode: true) == state(.battery, 0.5, lpm: true))
        #expect(state(.charging, 0.9).symbolName == "battery.100percent.bolt")
        #expect(state(.battery, 0.3).symbolName == "battery.25percent")
        #expect(state(.notCharging, 0.67).symbolName(charging: true) == "battery.75percent.bolt")  // the notice says Charging
    }

    @Test func noticesOnlyForChanges() {
        #expect(BatteryNotice.notice(from: nil, to: state(.charging)) == nil)                       // launch: quiet
        #expect(BatteryNotice.notice(from: state(.battery), to: state(.charging)) == .pluggedIn(charging: true))
        #expect(BatteryNotice.notice(from: state(.battery), to: state(.notCharging)) == .pluggedIn(charging: false))
        #expect(BatteryNotice.pluggedIn(charging: false).title == "Plugged In")  // from 80% up: never a wrong claim
        #expect(BatteryNotice.notice(from: state(.charging), to: state(.charged)) == .fullyCharged)
        #expect(BatteryNotice.notice(from: state(.battery), to: state(.battery, lpm: true)) == .lowPowerMode(on: true))
        #expect(BatteryNotice.notice(from: state(.charging), to: state(.battery)) == nil)           // unplugging: quiet
        #expect(BatteryNotice.notice(from: state(.charging, 0.5), to: state(.charging, 0.6)) == nil)
    }

    /// Your reports (2026-10-02 to -05): "Charging Paused" while charging at 65, 67, 83 and 89%. macOS's flag turns on
    /// 3–10 s after plugging in, so the words are only ones that are sure at once.
    @Test func plugInWordsAreSureOnes() {
        #expect(PlugInRules.notice(for: state(.notCharging, 0.67)) == .pluggedIn(charging: true))   // flag lagging
        #expect(PlugInRules.notice(for: state(.charging, 0.65)) == .pluggedIn(charging: true))
        #expect(PlugInRules.notice(for: state(.notCharging, 0.89)) == .pluggedIn(charging: false))  // "Plugged In"
        #expect(PlugInRules.notice(for: state(.charging, 0.85)) == .pluggedIn(charging: true))      // the flag is on: sure
        #expect(PlugInRules.notice(for: state(.charged, 1)) == .fullyCharged)
        #expect(PlugInRules.notice(for: state(.battery, 0.9)) == nil)
    }
}

struct HeadphonesNoticeRulesTests {
    /// Your 3-day check (2026-10-05): earbuds re-announced themselves every 3–15 min; 93 notices in 1.5 days.
    @Test func oneNoticePerDevicePerHalfHour() {
        let t0 = Date()
        #expect(HeadphonesNoticeRules.shows(after: nil, at: t0))                             // first time: shows
        #expect(!HeadphonesNoticeRules.shows(after: t0, at: t0.addingTimeInterval(10 * 60))) // 10 min later: quiet
        #expect(HeadphonesNoticeRules.shows(after: t0, at: t0.addingTimeInterval(31 * 60)))  // after half an hour: shows
    }
}

struct HeadphonesTests {
    @Test func unknownPartsAreNil() {
        // Your AirPods on 2026-09-30: left 100, right 100, case 88; "single" and "combined" read 0.
        let pods = HeadphonesBattery.from(name: "Sam’s AirPods Pro", left: 100, right: 100, caseLevel: 88, single: 0)
        #expect(pods == HeadphonesBattery(name: "Sam’s AirPods Pro", left: 100, right: 100, caseLevel: 88))
        #expect(pods?.symbolName == "airpodspro")
        #expect(HeadphonesBattery.from(name: "Speaker", left: 0, right: 0, caseLevel: 0, single: 0) == nil)
    }

    @Test func aDoubleAnnouncementIsOneConnection() {
        var deduper = ConnectionDeduper()
        let start = Date()
        let first = deduper.isNew("a", at: start)
        let echo = deduper.isNew("a", at: start.addingTimeInterval(0.8))      // your reconnect, announced twice
        let other = deduper.isNew("b", at: start.addingTimeInterval(1))       // another device is its own
        deduper.disconnected("a")
        let backIn = deduper.isNew("a", at: start.addingTimeInterval(5))      // out and back in: new
        let later = deduper.isNew("a", at: start.addingTimeInterval(21))      // 16 s later: new
        #expect(first && !echo && other && backIn && later)
    }

    @Test func oddNamesAreDropped() {
        // What macOS 27 gave for your AirPods' name: an empty string, or a single control character.
        #expect(DeviceNames.usable("\u{2}") == nil)
        #expect(DeviceNames.usable("  ") == nil)
        #expect(DeviceNames.usable("Sam’s AirPods Pro") == "Sam’s AirPods Pro")
        // Yours: vendor 76 (Apple), product 0x200E (8206).
        #expect(DeviceNames.appleProduct(vendorID: 76, productID: 8206) == "AirPods Pro")
        #expect(DeviceNames.appleProduct(vendorID: 0, productID: 8206) == nil)
        let pods = HeadphonesBattery.from(name: "\u{2}", left: 100, right: 100, caseLevel: 88, single: 0)
        #expect(pods?.name == nil)
        #expect(pods?.symbolName == "airpods")
        #expect(HeadphonesBattery(single: 70).symbolName == "headphones")
    }
}

/// Settings → Island → Appearance (added 2026-09-29).
public enum IslandAppearance: String, Equatable, Sendable, CaseIterable {
    /// Liquid Glass on macOS 26+ (frosted glass on 14–15). Floats 6 pt below the top edge.
    case liquidGlass = "glass"
    /// Solid black, hanging from the top edge like the notch on newer MacBooks.
    case black
    /// Solid black in Liquid Glass's floating pill: same shape, place and motion (your pick, 2026-10-29).
    case blackPill

    public var title: String {
        switch self {
        case .liquidGlass: "Liquid Glass"
        case .black: "Notch"  // your rename, 2026-10-29 (the saved value stays "black")
        case .blackPill: "Black Pill"
        }
    }

    /// Solid black with white content (Black and Black Pill). Shape and place: `== .black` is the notch; the others float.
    public var isSolidBlack: Bool { self != .liquidGlass }
}

/// Settings → Island → how the kept music indicator looks (added 2026-09-29).
/// What the island does over a full-screen window (Settings → Island → In full-screen apps).
public enum FullScreenIsland: String, Equatable, Sendable, CaseIterable {
    /// Nothing rests and only important notices show (your pick, 2026-10-02: even the slim line drew the eye in a
    /// full-screen video). It still opens from the top.
    case hide
    /// Music and Live Activities rest as the slim line (0.14.3).
    case slimLine = "slim"

    public var title: String {
        switch self {
        case .hide: "Hide"
        case .slimLine: "Slim line"
        }
    }
}

public enum KeptStyle: String, Equatable, Sendable, CaseIterable {
    /// Artwork, song, artist, and the moving waveform.
    case pill
    /// A thin line at the very top edge, so it never covers an app's toolbar.
    /// The HUD still shows the full pill; a new song only changes the line's colour (decision 12); opening follows the
    /// top-edge switches.
    case slimLine = "slim"

    public var title: String {
        switch self {
        case .pill: "Pill"
        case .slimLine: "Slim line"
        }
    }
}

/// The two buttons beside the play controls (C1, approved 2026-09-29).
public enum SideButtons: String, CaseIterable, Sendable {
    case shuffleRepeat
    /// The ★ stays on the left for every song and lights up where Brim can use it: Apple Music's Favorite, and
    /// Spotify's Liked Songs once Spotify is connected (0.18.3). The output button works for everything, videos too.
    case favoriteOutput

    public var title: String {
        switch self {
        case .shuffleRepeat: "Shuffle & Repeat"
        case .favoriteOutput: "Favorite & Output"
        }
    }

    /// The other pair: a sideways swipe on the controls row, or a click on its dot, switches to it (your pick,
    /// 2026-10-05).
    public var other: SideButtons {
        switch self {
        case .shuffleRepeat: .favoriteOutput
        case .favoriteOutput: .shuffleRepeat
        }
    }
}

/// What sits in each side slot, worked out from your setting and what the player can do. Pure, so tested.
public enum SideSlot: Equatable, Sendable {
    case shuffle, `repeat`, favorite, output

    /// `unreachable`: Spotify or Music is showing but didn't answer Brim.
    public static func slots(buttons: SideButtons, modes: PlayerModes?, player: ScriptablePlayer?,
                             skipButtons: Bool, unreachable: Bool = false) -> (left: SideSlot?, right: SideSlot?) {
        switch buttons {
        case .shuffleRepeat:
            // When the player answers, and also (faded, with the reason) when it's Spotify or Music but didn't: they
            // vanished while Spotify 1.3.3 ignored Brim (your report, 2026-10-02). Videos and podcasts have neither.
            guard !skipButtons, modes != nil || (player != nil && unreachable) else { return (nil, nil) }
            return (.shuffle, .repeat)
        case .favoriteOutput:
            // The button you chose, always (your report, 2026-09-30: with Spotify, Shuffle showed instead of ★).
            // Videos and podcasts have no favorite, so it steps aside for them, like Shuffle & Repeat.
            return (skipButtons ? nil : .favorite, .output)
        }
    }

    /// ★ works where the player said whether the song is a favorite: Music, and Spotify through its Web API (0.18.3).
    public static func canFavorite(modes: PlayerModes?, player: ScriptablePlayer?) -> Bool {
        player != nil && modes?.favorite != nil
    }

    /// Why the buttons Brim sends straight to Spotify or Music are faded, said on hover.
    public static func unreachableReason(player: ScriptablePlayer?) -> String {
        let name = player == .music ? "Music" : "Spotify"
        return "Brim can't reach \(name) right now. \(name)'s own controls still work."
    }

    /// Why Spotify's Shuffle and Repeat are faded while it's in the background (measured 2026-10-02, Spotify 1.3.3).
    public static let spotifyOnlyInFrontReason =
        "Spotify lets Shuffle and Repeat change only while it's in front. Its own buttons work."

    /// Why ★ is dimmed, said on hover. `needsReconnect`: Spotify was connected before ★ came to it (0.18.3).
    public static func favoriteUnavailableReason(player: ScriptablePlayer?, unreachable: Bool = false,
                                                 needsReconnect: Bool = false) -> String {
        if unreachable, player != nil { return unreachableReason(player: player) }
        return switch player {
        case .spotify? where needsReconnect:
            "To use ★ with Spotify, connect it again: Settings → Media & Lyrics → Disconnect, then Connect. "
                + "Spotify asks once to let Brim save songs."
        case .spotify?: "★ for Spotify needs Spotify Premium, connected in Settings → Media & Lyrics."
        case .music?: "Music can't favorite this song."
        case nil: "★ works with Apple Music and Spotify."
        }
    }
}

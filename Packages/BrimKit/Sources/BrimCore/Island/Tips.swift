import Foundation

/// The small things nobody finds by themselves (your goal, 2026-11-11). Each tip shows once, under the open island,
/// the first time you reach the thing it's about: no tour to sit through.
public enum Tip: String, CaseIterable, Sendable {
    /// The right-click menu: Settings, Keep Mac Awake, a quick timer. (Not sold as "timers": the Timers tab is
    /// right there; the menu's Start Timer stays as a two-click shortcut. Your pick, 2026-11-11.)
    case menu
    /// The cover opens the full-screen player.
    case cover
    /// The two-finger swipe between Shuffle & Repeat and Favorite & Output.
    case swipe
    /// The lyrics' own right-click menu: earlier, later, other versions.
    case lyrics

    /// One short line, in Brim's own voice.
    public var text: String {
        switch self {
        case .menu: "Two-finger click me for Settings and more."
        case .cover: "Click the cover for full screen."
        case .swipe: "Swipe two fingers on the buttons for more."
        case .lyrics: "Two-finger click the lyrics to shift their timing."
        }
    }
}

public enum TipRules {
    /// The next tip for this opening of the island, or nil: one per opening, in a fixed order, only where the thing
    /// it points at is on screen.
    public static func next(seen: Set<String>, page: ExpandedPage, hasSong: Bool, lyricsShowing: Bool) -> Tip? {
        Tip.allCases.first { tip in
            guard !seen.contains(tip.rawValue) else { return false }
            switch tip {
            case .menu: return true
            case .cover, .swipe: return page == .music && hasSong
            case .lyrics: return page == .music && lyricsShowing
            }
        }
    }

    /// A tip counts as seen once it has been up this long (a glimpse while the island closes doesn't).
    public static let readTime: TimeInterval = 1.5
}

import CoreGraphics
import BrimCore

/// Every island size in one place (PRD §7.1). Points, measured on a 1440 × 900 pt screen.
public enum IslandMetrics {
    /// The panel never changes size: the largest island (460 × 200) plus the gap.
    /// SwiftUI animates the island's shape inside it, because resizing a window mid-animation stutters.
    public static let panelSize = CGSize(width: 460, height: 300)
    /// The invisible strip at the very top that notices the pointer.
    public static let hoverStrip = CGSize(width: 240, height: 2)
    /// The kept pill, artwork and waveform only (your picks from mockups, 2026-09-30): Liquid Glass 128 × 34
    /// (small but substantial), Black 185 × 32 (exactly a 14" MacBook Pro notch).
    public static func pillSize(appearance: IslandAppearance,
                                geometry: IslandDisplayGeometry = .reference) -> CGSize {
        switch appearance {
        case .liquidGlass, .blackPill: CGSize(width: 128, height: 34)
        case .black: CGSize(width: geometry.blackPillWidth, height: 32)
        }
    }
    /// The kept pill's artwork: 59% of its height, 20 pt in Glass and 19 in Black (your pick from a side-by-side,
    /// 2026-10-01; it was 24 / 22, which nearly touched the capsule). ~7 pt clear on every side, like the waveform.
    public static func pillArtSize(appearance: IslandAppearance,
                                   geometry: IslandDisplayGeometry = .reference) -> CGFloat {
        (pillSize(appearance: appearance, geometry: geometry).height * 0.59).rounded()
    }
    /// Every glance (song change, battery, AirPods, calendar, timer notices, Time's up) has one size: 320 × the
    /// pill's height, so an event only ever grows the pill sideways (docs/05-interaction-model.md, 2026-09-30).
    public static let glanceWidth: CGFloat = 320
    public static func glanceSize(appearance: IslandAppearance,
                                  geometry: IslandDisplayGeometry = .reference) -> CGSize {
        CGSize(width: glanceWidth, height: pillSize(appearance: appearance, geometry: geometry).height)
    }
    /// The open island's tab row (icons at the top, your pick 2026-09-30), always there when it's open.
    public static let tabBarHeight: CGFloat = 28
    /// The Timers tab: Focus | Break, the ruler, Start; then 0, 1 or 2 rows of timers (more scroll).
    public static func timersHeight(rows: Int) -> CGFloat {
        140 + (rows <= 0 ? 0 : rows == 1 ? 38 : 72)
    }
    /// The Calendar tab: the time and date, then up to 3 rows of the day (more scroll); one message row when
    /// there's nothing (or the calendar is off).
    public static func calendarHeight(rows: Int) -> CGFloat {
        let visible = CGFloat(max(1, min(rows, 3)))
        return 10 + 26 + 8 + visible * 32 + (visible - 1) * 6 + 12
    }
    /// "Time's up" on the pill: a click this close to its right edge is Stop; the next 60 pt are Break.
    public static let timesUpStopZone: CGFloat = 56
    public static let timesUpBreakZone: CGFloat = 60
    /// A click this close to the calendar reminder's right edge is on its Join button.
    public static let reminderJoinZone: CGFloat = 64

    /// The timer ring beside the music pill (your picks, 2026-09-30). `centreOffset` is from the pill's centre,
    /// `top` from the screen's top edge.
    /// - Glass: 1.1 × the pill's height, 8 pt away, centred on the pill.
    /// - Black: a floating 30 pt circle, 4 pt below the edge, 12 pt from the notch. It never hangs from the edge.
    public static func timerBubble(appearance: IslandAppearance,
                                   geometry: IslandDisplayGeometry = .reference) -> (side: CGFloat, centreOffset: CGFloat, top: CGFloat) {
        let pill = pillSize(appearance: appearance, geometry: geometry)
        switch appearance {
        case .liquidGlass, .blackPill:
            let side = (pill.height * 1.1).rounded()
            return (side, pill.width / 2 + 8 + side / 2, topGap(for: .compact(.keptMusic), appearance: appearance) - (side - pill.height) / 2)
        case .black:
            let side: CGFloat = 30
            return (side, pill.width / 2 + notchShoulder(for: .compact(.keptMusic), geometry: geometry) + 12 + side / 2, 4)
        }
    }
    /// Black notch: the small inward curves where it meets the top edge. They sit outside the island's width.
    /// None on a detached shape (the Black HUD floats).
    public static func notchShoulder(for surface: IslandSurface,
                                     geometry: IslandDisplayGeometry = .reference) -> CGFloat {
        if surface.isHUD { return 0 }
        guard geometry.isNotched else { return surface == .slim ? 4 : 6 }
        let referenceWidth: CGFloat = 185
        let ratio = geometry.blackPillWidth / referenceWidth
        return (surface == .slim ? 4 : 6) * ratio
    }
    /// Black: the volume/brightness HUD lets go of the edge and floats as a capsule (your pick, 2026-09-30);
    /// everything else hangs with a flat top.
    public static func notchTopRadius(for surface: IslandSurface, appearance: IslandAppearance,
                                      geometry: IslandDisplayGeometry = .reference) -> CGFloat {
        surface.isHUD ? size(for: surface, appearance: appearance, geometry: geometry).height / 2 : 0
    }

    /// Distance from the top edge of the screen.
    /// Glass floats below the edge (the slim line closer to it); Black hangs from the edge like a notch, except
    /// the HUD, which floats like Glass (your pick, 2026-09-30).
    public static func topGap(for surface: IslandSurface, appearance: IslandAppearance) -> CGFloat {
        switch appearance {
        case .black: surface.isHUD ? 6 : 0
        case .liquidGlass, .blackPill: surface == .slim ? 3 : 6
        }
    }

    /// The slim line's parts (your pick A, 2026-09-30): the line itself (music), a dot for keep-awake on its left, and a
    /// draining bar for the next countdown on its right.
    public struct SlimParts: Equatable, Sendable {
        public var line: Bool
        public var dot: Bool
        public var bar: Bool

        public init(line: Bool = true, dot: Bool = false, bar: Bool = false) {
            self.line = line
            self.dot = dot
            self.bar = bar
        }
    }

    /// Glass: the line 120, the dot 4, the bar 22, 4 pt apart. Black: inside the notch the line is 104, the dot 4, the
    /// bar 16, 5 pt apart, with the notch's 18 pt margins.
    public static func slimPartWidths(appearance: IslandAppearance,
                                      geometry: IslandDisplayGeometry = .reference) -> (line: CGFloat, dot: CGFloat, bar: CGFloat, gap: CGFloat) {
        guard appearance == .black else { return (120, 4, 22, 4) }
        let scale = geometry.blackPillWidth / 185
        return (104 * scale, 4, 16 * scale, 5)
    }

    /// How far right of the slim line's middle its countdown bar starts (clicks from there open the countdown's tab).
    public static func slimBarStart(appearance: IslandAppearance, parts: SlimParts,
                                    geometry: IslandDisplayGeometry = .reference) -> CGFloat {
        let w = slimPartWidths(appearance: appearance, geometry: geometry)
        let pieces = [parts.dot ? w.dot : nil, parts.line ? w.line : nil, parts.bar ? w.bar : nil].compactMap { $0 }
        let inner = pieces.reduce(0, +) + w.gap * CGFloat(max(pieces.count - 1, 0))
        return inner / 2 - w.bar
    }

    static func slimSize(appearance: IslandAppearance, parts: SlimParts,
                         geometry: IslandDisplayGeometry = .reference) -> CGSize {
        let w = slimPartWidths(appearance: appearance, geometry: geometry)
        let pieces = [parts.dot ? w.dot : nil, parts.line ? w.line : nil, parts.bar ? w.bar : nil].compactMap { $0 }
        let inner = pieces.reduce(0, +) + w.gap * CGFloat(max(pieces.count - 1, 0))
        return appearance == .black ? CGSize(width: inner + 36, height: 9) : CGSize(width: inner, height: 4)
    }

    /// `agendaRows`: today's events in the Calendar tab (up to 3 show, more scroll).
    /// `timerRows`: timers running (the Timers tab lists up to two, then scrolls).
    /// `slim`: what the slim line carries.
    public static func size(for surface: IslandSurface, appearance: IslandAppearance, agendaRows: Int = 0,
                            timerRows: Int = 0, slim: SlimParts = SlimParts(),
                            geometry: IslandDisplayGeometry = .reference) -> CGSize {
        switch surface {
        case .hidden: CGSize(width: 180, height: 26)
        // Thin enough to cover no toolbar controls, which start about 8 pt below the edge.
        case .slim: slimSize(appearance: appearance, parts: slim, geometry: geometry)
        case .compact(.keptMusic): pillSize(appearance: appearance, geometry: geometry)
        // Volume and brightness show inside the pill, at its size: the pill never changes shape for a key press.
        // The charging notice too (your report, 2026-10-29: it was longer than the volume HUD for a percentage).
        case .compact(.hud), .compact(.timer), .compact(.battery): pillSize(appearance: appearance, geometry: geometry)
        // Keep-awake alone, and Brim asleep: a small pill, twice as wide as it is tall.
        case .compact(.keepAwake), .compact(.resting): CGSize(width: pillSize(appearance: appearance, geometry: geometry).height * 2,
                                           height: pillSize(appearance: appearance, geometry: geometry).height)
        // AirPods: wider than the pill, but not by much (your pick, 2026-10-30: 320 was too long).
        case .compact(.headphones):
            CGSize(width: 260, height: pillSize(appearance: appearance, geometry: geometry).height)
        case .compact(.nowPlaying), .compact(.calendar), .compact(.timerNotice), .compact(.timerDone):
            glanceSize(appearance: appearance, geometry: geometry)
        // Every tab has the tab row on top.
        case .expanded(.music): CGSize(width: geometry.expandedWidth, height: 170 + tabBarHeight)
        case .expanded(.timers): CGSize(width: geometry.expandedWidth, height: timersHeight(rows: timerRows) + tabBarHeight)
        case .expanded(.calendar): CGSize(width: geometry.expandedWidth, height: calendarHeight(rows: agendaRows) + tabBarHeight)
        }
    }

    /// Compact shapes are capsules, the HUD included ("the whole island is the slider", 2026-09-29).
    /// Open: 24 pt. In Black these are the notch's bottom corners.
    public static func cornerRadius(for surface: IslandSurface, appearance: IslandAppearance,
                                    geometry: IslandDisplayGeometry = .reference) -> CGFloat {
        switch surface {
        case .hidden, .slim, .compact: size(for: surface, appearance: appearance, geometry: geometry).height / 2
        case .expanded: 24
        }
    }

    /// Lowest point the pill reaches. Apple's volume/brightness HUD starts about 40 pt from the top; the pill
    /// never overlaps it when "Show only Brim's HUD" is off (tested in IslandMetricsTests). Glass B floating
    /// 6 pt down ends exactly at 40: touching, never covering (your pick, kept as you saw it).
    public static func pillBottom(appearance: IslandAppearance,
                                  geometry: IslandDisplayGeometry = .reference) -> CGFloat {
        let pill = IslandSurface.compact(.keptMusic)
        return topGap(for: pill, appearance: appearance) + size(for: pill, appearance: appearance, geometry: geometry).height
    }
}

/// What you use, counted for the 7-day run (your pick, 2026-10-01), so the week's review can say what you used and
/// what you never touched. Local and numbers only: never titles, names, or anything you typed. The health log writes
/// the counts with its 10-minute line (and at quit), then they start afresh.
@MainActor
public enum Usage {
    private static var counts: [String: Int] = [:]

    public static func note(_ what: String) {
        counts[what, default: 0] += 1
    }

    /// The counts since the last call, then empty.
    public static func take() -> [String: Int] {
        defer { counts = [:] }
        return counts
    }
}

extension IslandActivity.Kind {
    /// A short, stable name for the usage counts.
    public var usageName: String {
        switch self {
        case .nowPlaying: "music"
        case .keptMusic: "keptMusic"
        case .hud(let kind): kind == .volume ? "volume" : "brightness"
        case .battery: "battery"
        case .headphones: "airpods"
        case .calendar: "calendar"
        case .timer: "timer"
        case .timerNotice: "timerNotice"
        case .timerDone: "timesUp"
        case .keepAwake: "keepAwake"
        case .resting: "resting"
        }
    }
}

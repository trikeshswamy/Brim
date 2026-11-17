import SwiftUI
import Observation
import BrimCore

/// Which tip is up under the open island. What you've already seen is kept in Settings (`tipsSeen`), so "Show Tips
/// Again" in Settings → Help & Feedback is one line.
///
/// While the island stays open the tips take turns (your report, 2026-11-11: the next one only came after leaving
/// Brim and coming back): each stays `dwell` seconds, counts as seen, and makes room for the next one that fits
/// what's on screen now. So turning lyrics on with the island open brings the lyrics tip without closing it.
@Observable
public final class TipsStore {
    /// What's on screen in the open island: decides which tips fit.
    public struct Showing: Equatable, Sendable {
        public var page: ExpandedPage
        public var hasSong: Bool
        public var lyricsShowing: Bool
        public init(page: ExpandedPage, hasSong: Bool, lyricsShowing: Bool) {
            self.page = page
            self.hasSong = hasSong
            self.lyricsShowing = lyricsShowing
        }
    }

    public private(set) var current: Tip?
    @ObservationIgnored private let settings: IslandSettings
    @ObservationIgnored private var shownAt: Date?
    @ObservationIgnored private var turns: Task<Void, Never>?
    /// How long after the island opens the first tip comes out (zero in tests).
    @ObservationIgnored private let delay: Duration
    /// How long a tip stays before the next one takes its place.
    @ObservationIgnored private let dwell: Duration
    @ObservationIgnored private let now: () -> Date

    public init(settings: IslandSettings, delay: Duration = .milliseconds(600), dwell: Duration = .seconds(5),
                now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.delay = delay
        self.dwell = dwell
        self.now = now
    }

    /// The island opened. `showing` is asked again before each tip, so it follows what you do while it's open.
    public func islandOpened(_ showing: @escaping () -> Showing) {
        guard settings.tipsEnabled, turns == nil else { return }
        turns = Task { [weak self] in
            guard let self else { return }
            if delay > .zero { try? await Task.sleep(for: delay) }
            while !Task.isCancelled {
                let seen = Set(settings.tipsSeen)
                guard seen.count < Tip.allCases.count, settings.tipsEnabled else { return }  // nothing left to say
                let on = showing()
                guard let tip = TipRules.next(seen: seen, page: on.page, hasSong: on.hasSong,
                                              lyricsShowing: on.lyricsShowing) else {
                    // Nothing fits what's on screen: look again in a moment (you may turn lyrics on, start a song).
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                current = tip
                shownAt = now()
                Usage.note("tip.\(tip.rawValue)")
                try? await Task.sleep(for: dwell)
                guard !Task.isCancelled else { return }
                markSeen(tip)
                current = nil
                shownAt = nil
                try? await Task.sleep(for: .milliseconds(450))  // the old one leaves before the next arrives
            }
        }
    }

    /// The island closed: a tip that was up long enough to read never shows again.
    public func islandClosed() {
        turns?.cancel()
        turns = nil
        guard let tip = current else { return }
        if let shownAt, now().timeIntervalSince(shownAt) >= TipRules.readTime { markSeen(tip) }
        current = nil
        shownAt = nil
    }

    /// You did the thing yourself (clicked the cover, swiped the buttons): no need to tell you.
    public func learned(_ tip: Tip) {
        markSeen(tip)
        if current == tip { current = nil }
    }

    private func markSeen(_ tip: Tip) {
        if !settings.tipsSeen.contains(tip.rawValue) { settings.tipsSeen.append(tip.rawValue) }
    }
}

/// A tip under the open island: Brim's eyes looking up at the thing, and one line. Solid black in every look, so it
/// reads on any wallpaper. It can't be clicked: it never takes a click from what's under it.
struct TipBubble: View {
    let tip: Tip

    var body: some View {
        HStack(spacing: 8) {
            BrimFace(mood: .awake, gaze: CGSize(width: 0, height: -0.9), eye: CGSize(width: 7, height: 9), spacing: 5)
            Text(tip.text).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(.black, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tip: \(tip.text)")
    }

    static let height: CGFloat = 30
    /// Its height with the gaps around it: the island only shows a tip when this fits in its window.
    static let room: CGFloat = height + 16
}

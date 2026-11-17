import Foundation
import Observation
import BrimCore

/// The only thing that decides what the island shows (architecture D8).
///
/// Features post activities ("the track changed"); the window reports hover. The decision itself is
/// `IslandRules.surface(for:at:)`, a pure function with unit tests. This class only keeps the state and
/// wakes up once, at the next moment the answer can change. Never on a repeating timer.
@Observable
public final class IslandCoordinator {
    public private(set) var surface: IslandSurface = .hidden
    /// A glance while the island is open: it shows as a banner at the top of the open island
    /// (docs/05-interaction-model.md). The HUD has its own slider banner; a song change needs none.
    public private(set) var banner: IslandActivity.Kind?
    /// The side bubbles you swiped away (decision 9, one at a time since your fix round 2): the pill stays. A swipe on
    /// the pill, the right-click menu, or something new on that side brings them back.
    public private(set) var hiddenBubbles: Set<BubbleSide> = []
    /// Any bubble hidden (the right-click menu then offers Show Live Activities).
    public var bubblesHidden: Bool { !hiddenBubbles.isEmpty }
    /// The slim line is showing kept music (its line); false when it only carries Live Activity marks.
    public private(set) var slimCarriesMusic = false
    /// The hand-off after the welcome is pointing at the island: resting Brim opens its eyes (2026-11-11).
    public var spotlit = false

    @ObservationIgnored private var state = IslandState()
    @ObservationIgnored private var wakeUp: Task<Void, Never>?
    @ObservationIgnored private let now: () -> Date
    /// Every change, in order (tests: the island must never blink through "hidden" between two states).
    @ObservationIgnored var onSurfaceChange: ((IslandSurface) -> Void)?

    /// `now` is injectable so tests can control time.
    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// A glance of this kind is up, or waiting for its turn (the headphones' late levels fill in only then).
    public func hasGlance(_ kind: IslandActivity.Kind) -> Bool {
        IslandRules.liveActivities(state.activities, at: now()).contains { $0.kind == kind }
    }

    /// Whether anything is playing right now, as last reported by the Now Playing store.
    public var media: MediaPresence { state.media }

    public func hoverChanged(_ hovering: Bool) {
        guard hovering != state.isHovering else { return }
        // Opening from the timer or a class reminder in the pill lands on its tab, not Music (your report, 2026-10-02).
        // Picked once, as it opens, so a notice ending while you're inside doesn't switch the tab under you.
        if hovering, !surface.isExpanded, state.openPage == nil, let page = IslandRules.page(opening: surface) {
            state.openPage = page
        }
        state.isHovering = hovering
        state.hoverEndedAt = hovering ? nil : now()
        reevaluate()
    }

    /// Show an activity. A newer activity of the same kind replaces the older one.
    public func post(_ activity: IslandActivity) {
        let counted: Bool = if case .hud = activity.kind { false } else { true }  // key presses are counted elsewhere
        if state.quiet, !activity.kind.getsThroughFocus {
            Log.island.debug("Quiet while focusing: skipped \(String(describing: activity.kind), privacy: .public)")
            if counted { Usage.note("glance.quieted.\(activity.kind.usageName)") }
            return
        }
        if counted { Usage.note("glance.\(activity.kind.usageName)") }
        let live = IslandRules.liveActivities(state.activities, at: now())
        state.activities = live.filter { $0.kind != activity.kind } + [activity]
        reevaluate()
    }

    public func setMedia(_ media: MediaPresence) {
        guard media != state.media else { return }
        state.media = media
        reevaluate()
    }

    public func setKeepPillVisible(_ keep: Bool) {
        guard keep != state.keepPillVisible else { return }
        state.keepPillVisible = keep
        reevaluate()
    }

    public func setFullScreenPlayerOpen(_ open: Bool) {
        guard open != state.fullScreenPlayerOpen else { return }
        state.fullScreenPlayerOpen = open
        if open { state.isHovering = false }
        reevaluate()
    }

    /// The first-launch welcome takes the island's place while it shows (critical item 3, 2026-10-25).
    public func setWelcomeOpen(_ open: Bool) {
        guard open != state.welcomeOpen else { return }
        state.welcomeOpen = open
        if open { state.isHovering = false }
        reevaluate()
    }

    /// A timer is running (F9).
    public func setTimerRunning(_ running: Bool) {
        guard running != state.timerRunning else { return }
        state.timerRunning = running
        reevaluate()
    }

    /// A Focus timer is counting down: only calendar reminders and Time's up interrupt (decision 11).
    public func setFocusing(_ focusing: Bool) {
        state.focusing = focusing
    }

    /// Keep-awake (F11).
    public func setKeepAwake(_ on: Bool) {
        guard on != state.keepAwake else { return }
        state.keepAwake = on
        reevaluate()
    }

    /// The two-finger swipe on the resting pill (docs/05-interaction-model.md, decision 9): on a bubble it hides that
    /// bubble only; on the pill it brings hidden bubbles back. The pill itself never hides. `available`: what would
    /// show if nothing were hidden. False when nothing changes on screen (no tick then).
    @discardableResult
    public func swipe(on side: BubbleSide?, available: SideBubbles) -> Bool {
        guard SideRules.showsBubbles(beside: surface),
              let next = SideRules.afterSwipe(on: side, available: available, hidden: hiddenBubbles) else { return false }
        hiddenBubbles = next
        Usage.note(side != nil ? "swipe.bubble" : next.isEmpty ? "swipe.pill.show" : "swipe.pill.hide")
        return true
    }

    /// Something new started on those sides (a timer, keep-awake, a class countdown), or you chose Show in the menu.
    public func showBubbles(_ sides: Set<BubbleSide> = [.left, .right]) {
        let still = hiddenBubbles.subtracting(sides)
        if still != hiddenBubbles { hiddenBubbles = still }
    }

    /// Hide Live Activities in the right-click menu: both sides.
    public func hideBubbles() {
        if hiddenBubbles != [.left, .right] { hiddenBubbles = [.left, .right] }
    }

    /// Ends an activity early: "Time's up" when you press Stop.
    public func dismiss(_ kind: IslandActivity.Kind) {
        guard state.activities.contains(where: { $0.kind == kind }) else { return }
        state.activities.removeAll { $0.kind == kind }
        reevaluate()
    }

    /// The open island's tabs. The pick lasts while the island stays open, and becomes the tab it opens on
    /// next time nothing plays.
    public func showPage(_ page: ExpandedPage) {
        guard surface.isExpanded, state.openPage != page else { return }
        Usage.note("tab.\(page)")
        state.openPage = page
        state.lastTab = page
        reevaluate()
    }

    /// Opens the island on a given page (clicking the timer bubble opens the timer's page, even with music on).
    public func open(page: ExpandedPage) {
        Usage.note("bubble.open.\(page)")
        state.openPage = page
        state.lastTab = page
        state.isHovering = true
        state.hoverEndedAt = nil
        reevaluate()
    }

    /// A macOS Focus's Brim filter turned on or off (`BrimFocusFilter`): its island, and only important notices.
    public func setFocusFilter(island: FocusIsland?, importantOnly: Bool) {
        guard island != state.focusIsland || importantOnly != state.focusImportantOnly else { return }
        state.focusIsland = island
        state.focusImportantOnly = importantOnly
        Log.island.notice("Focus filter: island \(island?.rawValue ?? "as usual", privacy: .public), important only: \(importantOnly, privacy: .public)")
        reevaluate()
    }

    /// The front window entered or left macOS full screen (`FrontFullScreenWatcher`).
    public func setFrontIsFullScreen(_ full: Bool) {
        guard full != state.frontIsFullScreen else { return }
        state.frontIsFullScreen = full
        reevaluate()
    }

    public func setFullScreenIsland(_ choice: FullScreenIsland) {
        guard choice != state.fullScreen else { return }
        state.fullScreen = choice
        reevaluate()
    }

    public func setKeptStyle(_ style: KeptStyle) {
        guard style != state.keptStyle else { return }
        state.keptStyle = style
        reevaluate()
    }

    /// Settings → Island → "When nothing plays": Brim asleep, the slim line, or hidden.
    public func setIdleStyle(_ style: IdleStyle) {
        guard style != state.idleStyle else { return }
        state.idleStyle = style
        reevaluate()
    }

    /// Internal (not private) so tests can do what the scheduled wake-up does.
    func reevaluate() {
        let date = now()
        // The page choice lasts while the island stays open.
        if state.openPage != nil, !state.isHovering, IslandRules.surface(for: state, at: date).isExpanded == false {
            state.openPage = nil
        }
        state.activities = IslandRules.queued(state.activities, at: date)
        let next = IslandRules.surface(for: state, at: date)
        let top = IslandRules.liveActivities(state.activities, at: date).first
        let newBanner = next.isExpanded ? top.flatMap { $0.waitsForTurn && $0.start <= date ? $0.kind : nil } : nil
        if newBanner != banner { banner = newBanner }
        // The slim line shows the music line only while music is kept; otherwise just its Live Activity marks.
        // (Resting with nothing else on the line, it draws the line too: there must be something to see.)
        let restingLine = next == .slim && !state.timerRunning && !state.keepAwake
        let music = next == .slim && (IslandRules.showsKeptPill(state, at: date) || restingLine)
        if music != slimCarriesMusic { slimCarriesMusic = music }
        if next != surface {
            surface = next
            onSurfaceChange?(next)
            Log.island.notice("Island → \(String(describing: next), privacy: .public)")  // kept: user-reported looks can be traced
        }
        wakeUp?.cancel()
        guard let change = IslandRules.nextChange(for: state, after: date) else { return }
        let delay = max(0, change.timeIntervalSince(date))
        wakeUp = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reevaluate()
        }
    }
}

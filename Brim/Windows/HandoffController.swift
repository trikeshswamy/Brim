import AppKit
import SwiftUI
import BrimCore
import BrimFeatures

/// The hand-off's window (2026-11-11): the whole island screen, dimmed, one level under the island's panel so Brim
/// stays bright above it. It ignores the mouse entirely: pointing at the top opens the island as always, and that
/// (or any click, or 25 s) ends it.
@MainActor
final class HandoffController {
    private let island: IslandCoordinator
    private let settings: IslandSettings
    private let model = HandoffModel()
    private var panel: NSPanel?
    private var clickMonitors: [Any] = []
    private var timeout: Task<Void, Never>?
    private var watching = false

    init(island: IslandCoordinator, settings: IslandSettings) {
        self.island = island
        self.settings = settings
    }

    /// After the welcome's card has shrunk back into the pill (0.42 s) and the island has taken its place.
    func showSoon() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            self?.show()
        }
    }

    private func show() {
        guard panel == nil, let screen = ScreenLocator.islandScreen() else { return }
        let appearance = settings.appearance
        let resting = IslandSurface.compact(.keptMusic)
        let bottom = IslandMetrics.topGap(for: resting, appearance: appearance)
            + IslandMetrics.pillSize(appearance: appearance).height
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HandoffView(model: model, islandBottom: bottom))
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        island.spotlit = true
        model.showing = true
        Usage.note("handoff.show")

        // Any click ends it (the click still goes where you aimed it).
        let end: (NSEvent) -> Void = { [weak self] _ in Task { @MainActor in self?.dismiss(reason: "click") } }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: end) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { event in
            end(event)
            return event
        }) {
            clickMonitors.append(local)
        }
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(25))
            if !Task.isCancelled { self?.dismiss(reason: "timeout") }
        }
        // You pointed at the top: the island opened.
        watching = true
        observe { [weak self] in
            guard let self, self.watching else { return }
            if self.island.surface.isExpanded { self.dismiss(reason: "opened") }
        }
    }

    private func dismiss(reason: String) {
        guard let panel, model.showing else { return }
        watching = false
        model.showing = false
        island.spotlit = false
        timeout?.cancel()
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
        Usage.note("handoff.end.\(reason)")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))  // its fade
            panel.orderOut(nil)
            self?.panel = nil
        }
    }
}

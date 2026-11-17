import AppKit
import os
import BrimCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hover hints show after 0.25 s instead of macOS's ~1.5–3 s (your check, 2026-10-01: the ★'s reason took
        // 2–4 s). Brim's own setting only; every hint in Brim uses it.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 250])
        #if DEBUG
        if SafariScanBench.runIfRequested() { return }
        #endif
        let environment = AppEnvironment()
        self.environment = environment
        NSApp.mainMenu = makeMainMenu()
        quitCleanlyOnSIGTERM()
        environment.start()
        Log.app.notice("Brim launched")
    }

    /// By default SIGTERM (e.g. `kill`, `pkill`, our build script) ends the app instantly and skips
    /// `applicationWillTerminate`, leaving the helper behind. Route it through a normal quit instead.
    private func quitCleanlyOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)  // stop the default "exit now"; the dispatch source below handles it
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        source.resume()
        terminationSignal = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment?.stop()
        Log.app.notice("Brim quit")
    }

    /// Opening Brim again from Spotlight or Finder while it's running shows Settings (PRD F3).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        environment?.openSettings()
        return false
    }

    @objc func openSettings(_ sender: Any?) {
        environment?.openSettings()
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Now Playing uses mediaremote-adapter (BSD-3-Clause) by Jonas van den Berg."),
        ])
    }

    /// Only visible while Settings is open (the app is `.regular` then), so ⌘, ⌘W ⌘Q and copy/paste work.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Brim", action: #selector(showAbout(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Brim", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenuItem(app))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenuItem(edit))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenuItem(window))
        NSApp.windowsMenu = window

        return main
    }

    private func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }
}

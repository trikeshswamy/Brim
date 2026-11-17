import AppKit
import Sparkle

/// In-app updates with Sparkle (your go, 2026-10-29): once a day Brim reads the appcast on the public repo's latest
/// release; a new version is shown and installed only if you say so, and only if its EdDSA signature matches the key
/// in Info.plist. Debug builds never update themselves (a release would replace build/Brim.app).
@MainActor
final class Updates {
    private let controller: SPUStandardUpdaterController

    init() {
        #if DEBUG
        let start = false
        #else
        let start = true
        #endif
        controller = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Settings → About → Check for Updates…
    func check() {
        #if DEBUG
        let alert = NSAlert()
        alert.messageText = "Updates are off in debug builds"
        alert.informativeText = "Release builds check the public repo's latest release once a day."
        alert.runModal()
        #else
        controller.checkForUpdates(nil)
        #endif
    }
}

import AppKit

// Pure AppKit lifecycle (architecture D1): no SwiftUI `App`, so every window is under our control.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // no Dock icon, no menu bar, until Settings opens
app.run()

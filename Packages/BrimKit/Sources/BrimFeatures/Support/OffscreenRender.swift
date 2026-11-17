import SwiftUI

extension EnvironmentValues {
    /// Set by the snapshot tests. Offscreen rendering can't draw AppKit or Core Animation views (they come out as
    /// yellow placeholders), so the waveform, progress bar, and moving background draw still SwiftUI stand-ins.
    @Entry var offscreenRender = false
}

import Observation

/// Runs `apply` now, then again every time an `@Observable` property it read changes.
/// This is how AppKit code follows SwiftUI state, e.g. moving a window when the island changes.
/// (`withObservationTracking` reports only the first change, so this re-registers after each one.)
public func observe(_ apply: @escaping @MainActor @Sendable () -> Void) {
    withObservationTracking {
        apply()
    } onChange: {
        Task { @MainActor in observe(apply) }
    }
}

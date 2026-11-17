/// How ready an integration is. Every feature publishes one; the UI turns it into a visible state.
public enum Availability: Equatable, Sendable {
    case starting
    case ready
    case needsPermission
    case unavailable(reason: String)
}

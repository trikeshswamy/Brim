/// Whether Brim opens when you log in.
public enum LaunchAtLoginState: Equatable, Sendable {
    case on
    case off
    /// Registered, but you must allow it in System Settings → General → Login Items.
    case needsApproval
}

@MainActor
public protocol LaunchAtLoginControlling: AnyObject {
    var state: LaunchAtLoginState { get }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

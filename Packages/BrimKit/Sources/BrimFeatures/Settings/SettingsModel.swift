import Observation
import BrimCore

/// Settings state. For P-1 that's launch at login; more sections arrive with each checkpoint.
@Observable
public final class SettingsModel {
    public private(set) var launchAtLogin: LaunchAtLoginState
    public private(set) var launchAtLoginError: String?

    @ObservationIgnored private let launcher: any LaunchAtLoginControlling

    public init(launcher: any LaunchAtLoginControlling) {
        self.launcher = launcher
        launchAtLogin = launcher.state
    }

    /// Re-read the system's answer (you may have changed it in System Settings meanwhile).
    public func refresh() {
        launchAtLogin = launcher.state
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launcher.setEnabled(enabled)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refresh()
    }

    public func openLoginItems() {
        launcher.openSystemSettings()
    }
}

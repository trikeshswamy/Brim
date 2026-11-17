import ServiceManagement
import BrimCore

/// Launch at login through `SMAppService` (macOS 13+). No helper app, no LaunchAgent file to manage.
public final class LaunchAtLoginService: LaunchAtLoginControlling {
    public init() {}

    public var state: LaunchAtLoginState {
        switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        case .notRegistered, .notFound: .off
        @unknown default: .off
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

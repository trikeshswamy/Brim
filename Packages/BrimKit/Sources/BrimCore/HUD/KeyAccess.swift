/// Where Brim's hold on the volume and brightness keys stands. Settings shows it.
public enum KeyAccess: Equatable, Sendable {
    /// "Show only Brim's HUD" is off: macOS handles the keys and shows Apple's HUD.
    case off
    /// Waiting for Privacy & Security → Device Control and Data Access ("Accessibility" before macOS 27).
    case needsPermission
    /// Brim handles the keys; Apple's HUD doesn't appear.
    case active
    /// macOS refused the key tap even with the permission.
    case failed(String)
}

/// Takes over the volume, mute, and brightness keys.
/// The handler runs on the main thread for each of those key presses: returning `true` swallows the key
/// (macOS never sees it, so its HUD stays away); `false` hands it back to macOS.
/// Only media-key events are requested, never ordinary typing.
@MainActor
public protocol MediaKeyService: AnyObject {
    var access: KeyAccess { get }
    /// Read-only snapshot of macOS's Accessibility / Device Control grant.
    /// This is separate from `access`: the event tap can be off while the permission is already granted.
    var permissionGranted: Bool { get }
    var onAccessChange: ((KeyAccess) -> Void)? { get set }
    func refreshPermissionStatus()
    func start(handler: @escaping (MediaKeyPress) -> Bool)
    func stop()
}

import AppKit
import Foundation
import BrimCore

/// Spotify's and Music's own announcements, heard through system-wide notifications (no permission).
/// When either app quits, it's reported as stopped, so Brim never shows a player that's gone.
public final class DistributedPlayerAnnouncements: PlayerAnnouncementsService {
    public let announcements: AsyncStream<PlayerAnnouncement>
    private let continuation: AsyncStream<PlayerAnnouncement>.Continuation
    private var observers: [NSObjectProtocol] = []

    public init() {
        (announcements, continuation) = AsyncStream.makeStream(of: PlayerAnnouncement.self)
    }

    public func start() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        for player in ScriptablePlayer.allCases {
            let name = Notification.Name(PlayerAnnouncement.notificationName(for: player))
            observers.append(distributed.addObserver(forName: name, object: nil, queue: .main) { [continuation] note in
                guard let announcement = PlayerAnnouncement.parse(player: player, userInfo: note.userInfo ?? [:], at: .now) else { return }
                continuation.yield(announcement)
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [continuation] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let player = ScriptablePlayer(bundleID: app?.bundleIdentifier) else { return }
            continuation.yield(PlayerAnnouncement(player: player, state: .stopped, date: .now))
        })
    }
}

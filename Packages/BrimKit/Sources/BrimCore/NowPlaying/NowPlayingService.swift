import Foundation

/// Reports what's playing and controls it.
/// The live version (BrimSystem) talks to the helper; tests and previews use fakes.
@MainActor
public protocol NowPlayingService: AnyObject {
    /// Every change, in order. Exactly one consumer: the NowPlayingStore.
    var events: AsyncStream<NowPlayingEvent> { get }
    func start()
    func stop()
    func perform(_ command: MediaCommand) async
    func seek(to position: TimeInterval) async
    /// Shuffle on or off through macOS's Now Playing route, the way Control Center sets it. It reaches only the
    /// Now Playing app, so it's used only while that's Music (0.13.2, item 9).
    func setShuffle(_ on: Bool) async
    /// Repeat through the same route.
    func setRepeat(_ mode: RepeatMode) async
    /// Your Retry, when the helper keeps stopping: try now instead of waiting out the backoff.
    func retryNow()
}

public extension NowPlayingService {
    /// Fakes and benches have no helper to retry.
    func retryNow() {}
}

public enum NowPlayingEvent: Equatable, Sendable {
    /// `nil` = nothing is playing.
    case item(NowPlaying?)
    case availability(Availability)
    case helper(HelperStatus)
}

/// Shown in Settings → Diagnostics.
public struct HelperStatus: Equatable, Sendable {
    public var processID: Int32?
    public var restarts: Int

    public init(processID: Int32?, restarts: Int) {
        self.processID = processID
        self.restarts = restarts
    }
}

import Foundation
import Observation
import BrimCore

/// Your Spotify sign-in for Settings → Media & Lyrics (Shuffle & Repeat from anywhere, your decision 2026-10-02).
@Observable
public final class SpotifyAccountStore {
    public private(set) var state: SpotifyAccountState = .signedOut
    @ObservationIgnored private let service: any SpotifyAccountService

    public init(service: any SpotifyAccountService) {
        self.service = service
    }

    /// Settings calls this as the page opens.
    public func refresh() {
        Task { [service] in
            let now = await service.currentState()
            self.state = now
        }
    }

    /// Opens Spotify's sign-in in your browser; the state follows.
    public func signIn(clientID: String) {
        state = .signingIn
        Task { [service] in
            let result = await service.signIn(clientID: clientID)
            self.state = result
        }
    }

    public func signOut() {
        Task { [service] in
            await service.signOut()
            self.state = .signedOut
        }
    }
}

import Foundation
import Testing
@testable import BrimCore
@testable import BrimFeatures

/// Stands in for Spotify's sign-in.
actor FakeSpotifyAccount: SpotifyAccountService {
    var state: SpotifyAccountState = .signedOut
    private(set) var clientIDs: [String] = []
    var answer: SpotifyAccountState = .signedIn

    func currentState() async -> SpotifyAccountState { state }
    func signIn(clientID: String) async -> SpotifyAccountState {
        clientIDs.append(clientID)
        state = answer
        return answer
    }
    func signOut() async { state = .signedOut }
    func setAnswer(_ value: SpotifyAccountState) { answer = value }
}

/// Settings → Media & Lyrics → Spotify (your decision, 2026-10-02).
struct SpotifyAccountTests {
    private func settle(_ store: SpotifyAccountStore, until condition: (SpotifyAccountStore) -> Bool) async {
        for _ in 0..<200 where !condition(store) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func connectShowsWaitingThenConnected() async {
        let fake = FakeSpotifyAccount()
        let store = SpotifyAccountStore(service: fake)
        store.signIn(clientID: "abc123")
        #expect(store.state == .signingIn)        // while your browser has the sign-in
        await settle(store) { $0.state == .signedIn }
        #expect(store.state == .signedIn)
        #expect(await fake.clientIDs == ["abc123"])
        store.signOut()
        await settle(store) { $0.state == .signedOut }
        #expect(store.state == .signedOut)
    }

    @Test func aFailedSignInSaysWhy() async {
        let fake = FakeSpotifyAccount()
        await fake.setAnswer(.failed("The sign-in timed out. Try again."))
        let store = SpotifyAccountStore(service: fake)
        store.signIn(clientID: "abc123")
        await settle(store) { if case .failed = $0.state { true } else { false } }
        #expect(store.state == .failed("The sign-in timed out. Try again."))
    }

    @Test func theClientIDIsRemembered() {
        let defaults = UserDefaults(suiteName: testSuiteName("brim.spotify"))!
        let settings = IslandSettings(defaults: defaults)
        #expect(settings.spotifyClientID.isEmpty)
        settings.spotifyClientID = "abc123"
        #expect(IslandSettings(defaults: defaults).spotifyClientID == "abc123")
    }
}

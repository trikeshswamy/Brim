import AppKit
import Foundation
import Network
import Security
import BrimCore

/// Spotify's Web API for Shuffle & Repeat from anywhere (your decision, 2026-10-02; see `SpotifyWeb` for why and what it
/// needs) and ★ (0.18.3). Talks to Spotify only after you sign in, and only when the island reads Spotify's buttons (it
/// opens, the song changes) or you click Shuffle, Repeat or ★. Never on a timer. The sign-in stays in your Mac's
/// keychain; tokens and songs are never logged. Signed out, offline, or with nothing playing on any device, Brim falls
/// back to Spotify's menu (no ★ then).
public actor SpotifyWebAPI: SpotifyAccountService, SpotifyCoverService {
    private let session = URLSession(configuration: .ephemeral)
    private var access: (token: String, expires: Date)?
    /// One refresh at a time: two clicks mustn't both refresh (Spotify can replace the sign-in on each).
    private var refreshing: Task<String?, Never>?
    /// Spotify said "slow down" (429): nothing is sent until then.
    private var pausedUntil: Date?
    private var signingIn = false
    private var lastFailure: String?
    /// Whether this sign-in lets Brim see and change your Liked Songs (★). Nil until Spotify says: each token lists
    /// its permissions, and a refusal for a missing one also tells.
    private var likedSongsAllowed: Bool?

    public init() {}

    private var clientID: String? {
        UserDefaults.standard.string(forKey: SpotifyWeb.clientIDKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    public func currentState() async -> SpotifyAccountState {
        if signingIn { return .signingIn }
        if let lastFailure { return .failed(lastFailure) }
        return SpotifyKeychain.read() != nil && clientID != nil ? .signedIn : .signedOut
    }

    /// Opens Spotify's sign-in in your browser and waits (up to 5 minutes) for it to come back to 127.0.0.1.
    public func signIn(clientID: String) async -> SpotifyAccountState {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return .failed("Paste your Spotify app's Client ID first.") }
        UserDefaults.standard.set(id, forKey: SpotifyWeb.clientIDKey)
        signingIn = true
        lastFailure = nil
        defer { signingIn = false }
        let verifier = SpotifyWeb.makeVerifier()
        let state = UUID().uuidString
        let listener: LoopbackRedirect
        do {
            listener = try LoopbackRedirect(expectedState: state, port: SpotifyWeb.redirectPort)
            _ = try await listener.start()
        } catch {
            return fail("Brim couldn't listen on 127.0.0.1:\(SpotifyWeb.redirectPort) for the sign-in. Another app may be using that port; quit it and try again.")
        }
        let redirect = SpotifyWeb.registeredRedirect
        let url = SpotifyWeb.authorizeURL(clientID: id, redirect: redirect, challenge: SpotifyWeb.challenge(for: verifier), state: state)
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
        switch await listener.waitForCallback(timeout: 300) {
        case .code(let code):
            let tokens = await requestTokens([("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirect),
                                              ("client_id", id), ("code_verifier", verifier)], purpose: .signIn)
            guard let tokens, let refresh = tokens.refresh else {
                return fail(lastFailure ?? "Spotify didn't finish the sign-in. Try again.")
            }
            SpotifyKeychain.write(refresh)
            access = (tokens.access, Date().addingTimeInterval(tokens.expiresIn - 60))
            Log.nowPlaying.notice("Spotify Web API: signed in")
            return .signedIn
        case .refused(let why):
            return fail(why == LoopbackRedirect.timedOut ? "The sign-in timed out. Try again." : "Spotify didn't allow it (\(why)).")
        case .notOurs:
            return fail("The sign-in didn't come back. Try again.")
        }
    }

    public func signOut() async {
        SpotifyKeychain.delete()
        access = nil
        lastFailure = nil
        likedSongsAllowed = nil
        Log.nowPlaying.notice("Spotify Web API: signed out")
    }

    /// Whether Brim can ask the Web API at all (signed in, not told to slow down).
    public var isUsable: Bool {
        SpotifyKeychain.read() != nil && clientID != nil && (pausedUntil.map { Date() >= $0 } ?? true)
    }

    // MARK: Player

    /// Shuffle and all three Repeat states. Nil: signed out, offline, or nothing playing on any device (Spotify says 204).
    public func modes() async -> PlayerModes? {
        guard let (data, status) = await call("GET", "/me/player"), status == 200 else { return nil }
        return SpotifyWeb.modes(fromPlayer: data)
    }

    /// What Spotify on this Mac is playing, read once as Brim starts (0.18.2). Nil: signed out, offline, another device,
    /// or nothing playing.
    public func playerAnnouncement() async -> PlayerAnnouncement? {
        guard isUsable, let (data, status) = await call("GET", "/me/player"), status == 200 else { return nil }
        return SpotifyWeb.announcement(fromPlayer: data, at: Date())
    }

    public func setShuffle(_ on: Bool) async -> Bool {
        await call("PUT", "/me/player/shuffle?state=\(on)").map { (200...204).contains($0.status) } ?? false
    }

    public func setRepeat(_ mode: RepeatMode) async -> Bool {
        await call("PUT", "/me/player/repeat?state=\(SpotifyWeb.repeatState(mode))").map { (200...204).contains($0.status) } ?? false
    }

    // MARK: ★ Liked Songs (0.18.3)

    /// Whether the song is in your Liked Songs. `track`: the song Spotify's app announced; without one, the song the
    /// Web API says is playing. Nil: no song, not a track (local files, episodes, ads), not allowed, or no answer.
    public func liked(_ track: String?) async -> Bool? {
        guard likedSongsAllowed != false, let song = await songOrPlaying(track),
              let query = SpotifyWeb.libraryQuery(forTrack: song),
              let (data, status) = await call("GET", "/me/library/contains?" + query, logAs: "/me/library/contains")
        else { return nil }
        guard status == 200 else {
            noteRefusal(status, data)
            return nil
        }
        return SpotifyWeb.liked(fromContains: data)
    }

    /// The sign-in lacks the Liked Songs permissions: you connected before ★ came to Spotify. Connect again, once.
    public var likedSongsNeedReconnect: Bool { likedSongsAllowed == false }

    /// ★: adds the song to your Liked Songs, or takes it out (0.18.3). `track`: the song Spotify's app announced;
    /// without one, the song the Web API says is playing now.
    public func setLiked(_ on: Bool, track: String?) async -> Bool {
        guard likedSongsAllowed != false, let song = await songOrPlaying(track),
              let query = SpotifyWeb.libraryQuery(forTrack: song),
              let (data, status) = await call(on ? "PUT" : "DELETE", "/me/library?" + query, logAs: "/me/library")
        else { return false }
        guard (200...204).contains(status) else {
            noteRefusal(status, data)
            return false
        }
        Log.nowPlaying.notice("Spotify Web API: ★ \(on ? "added to" : "removed from", privacy: .public) Liked Songs")
        return true
    }

    private func songOrPlaying(_ track: String?) async -> String? {
        if let track { return track }
        guard let (data, status) = await call("GET", "/me/player"), status == 200 else { return nil }
        return SpotifyWeb.playingTrack(fromPlayer: data)
    }

    /// A refusal for a missing permission: a sign-in from before ★. Brim stops asking, and ★ says to connect again.
    private func noteRefusal(_ status: Int, _ data: Data) {
        if status == 403, SpotifyWeb.isMissingPermission(data) { noteLikedSongs(allowed: false) }
    }

    private func noteLikedSongs(allowed: Bool) {
        guard likedSongsAllowed != allowed else { return }
        likedSongsAllowed = allowed
        Log.nowPlaying.notice("Spotify Web API: ★ allowed: \(allowed, privacy: .public)")
    }

    // MARK: Covers

    /// A track's cover, for when macOS's Now Playing is on another app and Spotify's announcements carry none (0.17.3,
    /// your OK: Spotify's image server joins Brim's network list). Brim asks once per song, only while it shows Spotify
    /// on its own. The track is looked up on api.spotify.com; the image comes from i.scdn.co without your sign-in.
    public func cover(forTrack uri: String) async -> Data? {
        guard isUsable, let id = SpotifyWeb.trackID(fromURI: uri),
              let (data, status) = await call("GET", "/tracks/\(id)", logAs: "/tracks/…"), status == 200,
              let url = SpotifyWeb.coverURL(fromTrack: data) else { return nil }
        let request = URLRequest(url: url, timeoutInterval: 4)  // no Authorization header: the image server needs none
        guard let (image, response) = try? await session.data(for: request, delegate: NoRedirects()),
              (response as? HTTPURLResponse)?.statusCode == 200, !image.isEmpty, image.count < 3_000_000 else {
            Log.nowPlaying.notice("Spotify Web API: a cover didn't arrive")
            return nil
        }
        return image
    }

    /// Refuses redirects, so a cover only ever comes from the address Spotify named on i.scdn.co.
    private nonisolated final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    // MARK: Queue (2026-10-29)

    /// Spotify's Up Next (`user-read-playback-state`, already part of the sign-in), named after its playlist or album.
    public func queue() async -> PlayerQueue {
        guard isUsable, let (data, status) = await call("GET", "/me/player/queue"), status == 200 else { return .empty }
        let items = SpotifyWeb.queue(from: data)
        guard !items.isEmpty else { return .empty }
        return .items(source: await contextName(), items)
    }

    /// Plays a queued song now. From the playlist or album that's playing: that song, inside it, so the rest plays on
    /// after it. Not in it (a song Spotify added after the album, or one you queued yourself): that song now, with the
    /// rest of Up Next after it. Before 2026-11-17 Brim pressed Next once per song in between, so you heard each one
    /// start (your report). Pressing Next stays only as the last resort, if Spotify refuses both.
    public func play(_ item: QueueItem, position: Int) async -> Bool {
        guard isUsable, let uri = item.spotifyURI else { return false }
        if let context = await contextURI(), let body = SpotifyWeb.playBody(context: context, track: uri),
           let (_, status) = await call("PUT", "/me/player/play", logAs: "/me/player/play (in its playlist)", body: body),
           (200...204).contains(status) {
            return true
        }
        if let (data, status) = await call("GET", "/me/player/queue"), status == 200,
           let body = SpotifyWeb.listBody(queue: SpotifyWeb.queue(from: data), from: uri),
           let (_, played) = await call("PUT", "/me/player/play", logAs: "/me/player/play (Up Next from it)", body: body),
           (200...204).contains(played) {
            return true
        }
        // The last resort, quietly: Spotify's volume at 0 while it skips, then back (you heard each song start).
        let volume = await deviceVolume()
        if let volume, volume > 0 { _ = await call("PUT", "/me/player/volume?volume_percent=0") }
        var skipped = true
        for _ in 0...position {
            guard let (_, status) = await call("POST", "/me/player/next"), (200...204).contains(status) else { skipped = false; break }
            try? await Task.sleep(for: .milliseconds(150))  // one skip at a time, in order
        }
        if let volume, volume > 0 {
            try? await Task.sleep(for: .milliseconds(250))
            _ = await call("PUT", "/me/player/volume?volume_percent=\(volume)")
        }
        return skipped
    }

    /// The playing device's volume, 0–100; nil where Spotify can't change it (some speakers).
    private func deviceVolume() async -> Int? {
        guard let (data, status) = await call("GET", "/me/player"), status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = json["device"] as? [String: Any], device["supports_volume"] as? Bool != false,
              let volume = device["volume_percent"] as? Int else { return nil }
        return volume
    }

    private var contextNames: [String: String] = [:]

    private func contextURI() async -> String? {
        guard let (data, status) = await call("GET", "/me/player"), status == 200 else { return nil }
        return SpotifyWeb.contextURI(fromPlayer: data)
    }

    /// The playlist or album's name, asked once per playlist while Brim runs.
    private func contextName() async -> String? {
        guard let uri = await contextURI() else { return nil }
        if let known = contextNames[uri] { return known }
        guard let path = SpotifyWeb.contextNamePath(for: uri),
              let (data, status) = await call("GET", path, logAs: "/playlists or /albums (a name)"), status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else { return nil }
        contextNames[uri] = name
        return name
    }

    // MARK: Network

    /// `logAs`: what the log shows instead of the path, when the path names a song (a track ID is as telling as a title).
    private func call(_ method: String, _ path: String, logAs: String? = nil, body: Data? = nil,
                      retried: Bool = false) async -> (data: Data, status: Int)? {
        if let pausedUntil, Date() < pausedUntil { return nil }
        guard let token = await accessToken() else { return nil }
        let shown = logAs ?? path
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1" + path)!, timeoutInterval: 4)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
            if !Task.isCancelled {
                Log.nowPlaying.notice("Spotify Web API: \(method, privacy: .public) \(shown, privacy: .public) got no answer")
            }
            return nil
        }
        switch http.statusCode {
        case 401 where !retried:
            access = nil  // expired early: refresh once and try again
            return await call(method, path, logAs: logAs, body: body, retried: true)
        case 429:
            let wait = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
            pausedUntil = Date().addingTimeInterval(wait)
            Log.nowPlaying.notice("Spotify Web API: asked to wait \(Int(wait), privacy: .public) s")
            return nil
        case 200...299:
            return (data, http.statusCode)
        default:
            let reason = SpotifyWeb.reason(from: data) ?? "no reason"
            Log.nowPlaying.notice("Spotify Web API: \(method, privacy: .public) \(shown, privacy: .public) → \(http.statusCode, privacy: .public) \(reason, privacy: .public)")
            if reason == "PREMIUM_REQUIRED" { lastFailure = "Spotify says Shuffle and Repeat from Brim need Premium." }
            return (data, http.statusCode)
        }
    }

    private func accessToken() async -> String? {
        if let access, access.expires > Date() { return access.token }
        if let refreshing { return await refreshing.value }
        guard let refresh = SpotifyKeychain.read(), let id = clientID else { return nil }
        let task = Task { () -> String? in
            guard let tokens = await requestTokens([("grant_type", "refresh_token"), ("refresh_token", refresh), ("client_id", id)], purpose: .refresh) else {
                return nil
            }
            if let replaced = tokens.refresh { SpotifyKeychain.write(replaced) }
            access = (tokens.access, Date().addingTimeInterval(tokens.expiresIn - 60))
            return tokens.access
        }
        refreshing = task
        let token = await task.value
        refreshing = nil
        return token
    }

    private enum TokenPurpose {
        case signIn
        case refresh
    }

    private func requestTokens(_ fields: [(String, String)], purpose: TokenPurpose) async -> SpotifyWeb.Tokens? {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = SpotifyWeb.formBody(fields)
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
            Log.nowPlaying.notice("Spotify Web API: the sign-in service didn't answer")
            if purpose == .signIn { lastFailure = "Spotify did not answer. Check your internet connection and try again." }
            return nil
        }
        guard http.statusCode == 200 else {
            let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "\(http.statusCode)"
            Log.nowPlaying.notice("Spotify Web API: token request refused (\(error, privacy: .public))")
            if error == "invalid_grant", purpose == .refresh {  // the 6-month sign-in ended, or you removed Brim in Spotify
                SpotifyKeychain.delete()
                access = nil
                lastFailure = "Your Spotify sign-in ended. Connect again."
            } else if purpose == .signIn {
                switch error {
                case "invalid_client":
                    lastFailure = "Spotify rejected this Client ID. Check that it belongs to your Spotify app."
                case "invalid_grant":
                    lastFailure = "Spotify rejected the callback. Check that the registered redirect URI exactly matches \(SpotifyWeb.registeredRedirect), then try again in one normal browser window."
                default:
                    lastFailure = "Spotify sign-in failed (\(error)). Check the Client ID and redirect URI."
                }
            }
            return nil
        }
        let tokens = SpotifyWeb.tokens(from: data)
        if tokens == nil, purpose == .signIn { lastFailure = "Spotify returned an invalid token response." }
        if let scope = tokens?.scope { noteLikedSongs(allowed: SpotifyWeb.allowsLikedSongs(scope: scope)) }
        return tokens
    }

    /// Debug check (2026-10-02): the sign-in listener on 127.0.0.1:42813 receives a browser-style reply in the real app
    /// (signed, hardened runtime). Brim sends the reply to itself; nothing goes to Spotify.
    public static func listenerSelfTest() async -> String {
        do {
            let listener = try LoopbackRedirect(expectedState: "selftest", port: SpotifyWeb.redirectPort)
            let port = try await listener.start()
            async let answer = listener.waitForCallback(timeout: 5)
            var request = URLRequest(url: URL(string: SpotifyWeb.registeredRedirect + "?code=ok&state=selftest")!, timeoutInterval: 3)
            request.httpMethod = "GET"
            let status = ((try? await URLSession(configuration: .ephemeral).data(for: request))?.1 as? HTTPURLResponse)?.statusCode
            let callback = await answer
            return "port \(port), page \(status.map(String.init) ?? "none"), callback \(callback == .code("ok") ? "received" : "\(callback)")"
        } catch {
            return "listener failed: \(error)"
        }
    }

    private func fail(_ reason: String) -> SpotifyAccountState {
        lastFailure = reason
        Log.nowPlaying.notice("Spotify Web API: sign-in failed")
        return .failed(reason)
    }
}

/// The sign-in's refresh token in your login keychain (only Brim, signed with your certificate, reads it).
nonisolated enum SpotifyKeychain {
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.theojones.Brim.spotify",
         kSecAttrAccount as String: "refresh-token"]
    }

    static func read() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        let data = Data(value.utf8)
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete() { SecItemDelete(base as CFDictionary) }
}

/// Listens on 127.0.0.1 (the registered port) only while you sign in, for the browser's one redirect; answers with a
/// short page you can close.
nonisolated final class LoopbackRedirect: @unchecked Sendable {
    static let timedOut = "timed out"
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.theojones.Brim.spotify-signin")
    private let expectedState: String
    private let lock = NSLock()
    private var started: CheckedContinuation<UInt16, Error>?
    private var waiter: CheckedContinuation<SpotifyWeb.Callback, Never>?
    private var result: SpotifyWeb.Callback?

    init(expectedState: String, port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true  // a sign-in right after another
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        listener = try NWListener(using: parameters)
        self.expectedState = expectedState
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { started = continuation }
            listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    func waitForCallback(timeout seconds: Double) async -> SpotifyWeb.Callback {
        let callback = await withCheckedContinuation { continuation in
            let ready: SpotifyWeb.Callback? = lock.withLock {
                if let result { return result }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
            queue.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.finish(.refused(Self.timedOut)) }
        }
        listener.cancel()
        return callback
    }

    private func listenerChanged(_ state: NWListener.State) {
        let continuation: CheckedContinuation<UInt16, Error>? = lock.withLock {
            switch state {
            case .ready, .failed, .cancelled:
                defer { started = nil }
                return started
            default:
                return nil
            }
        }
        switch state {
        case .ready: continuation?.resume(returning: listener.port?.rawValue ?? 0)
        case .failed(let error): continuation?.resume(throwing: error)
        case .cancelled: continuation?.resume(throwing: CancellationError())
        default: break
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return connection.cancel() }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let callback = SpotifyWeb.callback(fromRequestLine: request.components(separatedBy: "\r\n").first ?? "",
                                               expectedState: self.expectedState)
            let message = switch callback {
            case .code: "Brim is connected to Spotify. You can close this tab."
            case .refused: "Brim isn't connected to Spotify. You can close this tab and try again from Brim's Settings."
            case .notOurs: "Not found."
            }
            let page = "<!doctype html><meta charset=utf-8><title>Brim</title><body style=\"font:16px -apple-system;margin:40px\">\(message)</body>"
            let status = callback == .notOurs ? "404 Not Found" : "200 OK"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if callback != .notOurs { self.finish(callback) }
        }
    }

    private func finish(_ callback: SpotifyWeb.Callback) {
        let continuation: CheckedContinuation<SpotifyWeb.Callback, Never>? = lock.withLock {
            guard result == nil else { return nil }
            result = callback
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume(returning: callback)
    }
}

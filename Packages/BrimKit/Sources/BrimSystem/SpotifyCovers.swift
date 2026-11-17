import Foundation
import BrimCore

/// A Spotify song's cover, free first (2026-10-29): the address from Spotify's own scripting, no Client ID needed; the
/// Web API only when you've connected it and the scripting didn't answer. Either way, only from Spotify's image server.
public struct SpotifyCovers: SpotifyCoverService {
    let web: SpotifyWebAPI
    let controls: AppleEventPlayerControls

    public init(web: SpotifyWebAPI, controls: AppleEventPlayerControls) {
        self.web = web
        self.controls = controls
    }

    public func cover(forTrack uri: String) async -> Data? {
        if let url = await controls.spotifyCoverURL(for: uri) {
            let request = URLRequest(url: url, timeoutInterval: 4)
            if let (image, response) = try? await URLSession.shared.data(for: request, delegate: NoRedirects()),
               (response as? HTTPURLResponse)?.statusCode == 200, !image.isEmpty, image.count < 3_000_000 {
                return image
            }
        }
        return await web.cover(forTrack: uri)
    }

    /// Refuses redirects, so a cover only ever comes from the address Spotify named on i.scdn.co.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}

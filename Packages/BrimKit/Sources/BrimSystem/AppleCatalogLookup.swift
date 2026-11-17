import Foundation
import BrimCore

/// Asks Apple's public catalog (itunes.apple.com) for an album's songs: two small requests per album, kept for the
/// session, nothing else sent (the song's title and lead artist, and your Mac's region). No cookies, no cache on disk.
actor AppleCatalogLookup {
    private let session = URLSession(configuration: .ephemeral)
    private var albums: [String: Data] = [:]

    func upNext(title: String, artist: String, album: String, trackNumber: Int?) async -> [QueueItem] {
        let country = (Locale.current.region?.identifier ?? "US").lowercased()
        let key = "\(country)|\(album)|\(artist)"
        if albums[key] == nil {
            guard let search = AppleCatalog.searchURL(title: title, artist: artist, country: country),
                  let found = await fetch(search),
                  let id = AppleCatalog.albumID(in: found, album: album),
                  let lookup = AppleCatalog.lookupURL(albumID: id, country: country),
                  let songs = await fetch(lookup) else { return [] }
            albums[key] = songs
        }
        guard let songs = albums[key] else { return [] }
        return AppleCatalog.upNext(in: songs, currentTitle: title, currentNumber: trackNumber)
    }

    /// A song's page in Apple Music's catalog (History: a streamed song that isn't in your Library).
    func songPage(title: String, artist: String) async -> URL? {
        let country = (Locale.current.region?.identifier ?? "US").lowercased()
        guard let search = AppleCatalog.searchURL(title: title, artist: artist, country: country),
              let found = await fetch(search) else { return nil }
        return AppleCatalog.songPage(in: found, title: title)
    }

    private func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Brim (macOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, url.host == "itunes.apple.com" else { return nil }
        return data
    }
}

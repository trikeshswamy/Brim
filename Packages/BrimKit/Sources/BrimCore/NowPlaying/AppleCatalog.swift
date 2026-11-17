import Foundation

/// Apple Music's free public catalog lookup (itunes.apple.com, no key), for the Queue when Music streams an album
/// that isn't in your Library and so has no playlist to share (your pick 2026-10-29). It lists the album's order, not
/// songs you added to Playing Next; clicking one opens it in Music.
public enum AppleCatalog {
    /// Find the album through the song playing: `search?entity=song` with its title and lead artist (searching for
    /// the album's own name found the wrong albums for a long soundtrack title, checked 2026-10-29).
    public static func searchURL(title: String, artist: String, country: String) -> URL? {
        let lead = LRCLIBVersions.searchArtists(for: artist).last ?? artist
        var parts = URLComponents(string: "https://itunes.apple.com/search")
        parts?.queryItems = [URLQueryItem(name: "term", value: "\(title) \(lead)"), URLQueryItem(name: "entity", value: "song"),
                             URLQueryItem(name: "limit", value: "10"), URLQueryItem(name: "country", value: country)]
        return parts?.url
    }

    /// Its songs: `lookup?id=<album>&entity=song`.
    public static func lookupURL(albumID: Int, country: String) -> URL? {
        var parts = URLComponents(string: "https://itunes.apple.com/lookup")
        parts?.queryItems = [URLQueryItem(name: "id", value: String(albumID)), URLQueryItem(name: "entity", value: "song"),
                             URLQueryItem(name: "country", value: country)]
        return parts?.url
    }

    /// The album of the search result that's on the album playing: the exact name first ("Abbey Road" isn't
    /// "Abbey Road (2019 Mix)"), else the closest.
    public static func albumID(in data: Data, album: String) -> Int? {
        let name = fold(album)
        func found(_ result: [String: Any]) -> String { fold(result["collectionName"] as? String ?? "") }
        let songs = results(data)
        let match = songs.first { found($0) == name }
            ?? songs.first { found($0).hasPrefix(name) || (!found($0).isEmpty && name.hasPrefix(found($0))) }
        return match?["collectionId"] as? Int
    }

    /// The album's songs after the playing one (found by title, else by track number), at most `QueueRules.limit`.
    public static func upNext(in data: Data, currentTitle: String, currentNumber: Int?) -> [QueueItem] {
        let songs = results(data)
            .filter { $0["wrapperType"] as? String == "track" }
            .sorted { (($0["discNumber"] as? Int ?? 1), ($0["trackNumber"] as? Int ?? 0))
                    < (($1["discNumber"] as? Int ?? 1), ($1["trackNumber"] as? Int ?? 0)) }
        let title = fold(currentTitle)
        let index = songs.firstIndex { fold($0["trackName"] as? String ?? "") == title }
            ?? songs.firstIndex { fold($0["trackName"] as? String ?? "").hasPrefix(title) }
            ?? currentNumber.flatMap { number in songs.firstIndex { $0["trackNumber"] as? Int == number } }
        guard let index else { return [] }
        return songs[(index + 1)...].prefix(QueueRules.limit).compactMap { song in
            guard let id = song["trackId"] as? Int, let name = song["trackName"] as? String else { return nil }
            return QueueItem(id: "apple:\(id)", title: name, artist: song["artistName"] as? String, sameAlbumAsPlaying: true,
                             storeURL: (song["trackViewUrl"] as? String).flatMap(URL.init(string:)))
        }
    }

    /// The search result that is the song: the exact title first, else one starting with it.
    public static func songPage(in data: Data, title: String) -> URL? {
        let name = fold(title)
        let songs = results(data).filter { $0["wrapperType"] as? String == "track" }
        let match = songs.first { fold($0["trackName"] as? String ?? "") == name }
            ?? songs.first { fold($0["trackName"] as? String ?? "").hasPrefix(name) }
        return (match?["trackViewUrl"] as? String).flatMap(URL.init(string:))
    }

    private static func results(_ data: Data) -> [[String: Any]] {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["results"] as? [[String: Any]] ?? []
    }

    /// Case, accents and punctuation don't matter.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
    }
}

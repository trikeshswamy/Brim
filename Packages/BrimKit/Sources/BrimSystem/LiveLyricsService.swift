import CryptoKit
import Foundation
import BrimCore

/// Lyrics from LRCLIB (lrclib.net), with a disk cache so each song is looked up at most once,
/// plus your per-song fixes (timing, chosen version).
///
/// - Brim's only network use. A lookup sends the song's title, artist, album, and length; "Try Another
///   Version" sends title and artist. Nothing else.
/// - Cached songs never touch the network again. "Not found" is remembered for 7 days (LRCLIB grows).
/// - The cache stays under 5 MB, oldest-used first out. Your fixes live apart from it, in Application
///   Support, which macOS never clears, so a fix can't vanish with the cache.
/// - A 429 ("slow down") reply pauses all requests until LRCLIB's Retry-After time.
/// An actor, so network and disk work run off the main thread.
public actor LiveLyricsService: LyricsService {
    private let session: URLSession
    private let cacheDirectory: URL
    private let choicesDirectory: URL
    private let userAgent: String
    private var pausedUntil: Date?

    private static let cacheLimit = 5 * 1024 * 1024
    private static let notFoundLifetime: TimeInterval = 7 * 24 * 60 * 60

    public init(userAgent: String) {
        let configuration = URLSessionConfiguration.ephemeral  // no cookies, no shared URL cache
        configuration.timeoutIntervalForRequest = 10
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(userAgent: userAgent, session: URLSession(configuration: configuration),
                  cacheDirectory: caches.appendingPathComponent("com.theojones.Brim/lyrics", isDirectory: true),
                  choicesDirectory: support.appendingPathComponent("com.theojones.Brim/lyrics-choices", isDirectory: true))
    }

    /// Tests pass temporary folders.
    init(userAgent: String, session: URLSession, cacheDirectory: URL, choicesDirectory: URL) {
        self.session = session
        self.userAgent = userAgent
        self.cacheDirectory = cacheDirectory
        self.choicesDirectory = choicesDirectory
    }

    /// Lookups since launch, for the health log. Numbers only.
    public struct Counters: Sendable, Equatable {
        /// Asked LRCLIB (not from the cache or your saved choice).
        public var fromNetwork = 0
        /// Found only by the second search, after `/api/get` missed.
        public var rescued = 0
        /// Untimed lyrics swapped for a timed version with the same words.
        public var madeTimed = 0
        public var notFound = 0
    }

    private var counters = Counters()

    public func currentCounters() -> Counters { counters }

    public func lyrics(for query: LyricsQuery) async -> LyricsResult {
        if let chosen = readChoice(for: query)?.record { return LRCLIBReply.decode(chosen) }
        if let cached = readCache(for: query) { return cached }
        counters.fromNetwork += 1

        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: query.title),
            URLQueryItem(name: "artist_name", value: query.artist),
            URLQueryItem(name: "album_name", value: query.album ?? ""),
            URLQueryItem(name: "duration", value: String(Int(query.duration.rounded()))),
        ]
        switch await send(components) {
        case .ok(let data):
            let result = LRCLIBReply.decode(data)
            switch result {
            case .found(.plain(let words)):
                // Timed lyrics may exist under a plainer title: one more look, and only the same words count.
                if let timed = await searchRecord(for: query, words: words).record {
                    counters.madeTimed += 1
                    return keep(timed, for: query)
                }
                writeCache(data, for: query, found: true)
                return result
            case .found:
                writeCache(data, for: query, found: true)
                return result
            case .notFound:
                return await rescue(query)
            default:
                return result
            }
        case .notFound:
            return await rescue(query)
        case .rateLimited(let until): return .rateLimited(until: until)
        case .offline: return .offline
        case .failed(let reason): return .failed(reason)
        }
    }

    /// `/api/get` missed: one search before giving up (the title as given, then without extras that keep the
    /// same recording). "Not found" is remembered only when the search itself got an answer.
    private func rescue(_ query: LyricsQuery) async -> LyricsResult {
        let search = await searchRecord(for: query, words: nil)
        if let record = search.record {
            counters.rescued += 1
            return keep(record, for: query)
        }
        counters.notFound += 1
        if search.answered { writeCache(Data(), for: query, found: false) }
        return .notFound
    }

    /// Searches the title as given, then its same-recording title if different; stops at the first good record.
    private func searchRecord(for query: LyricsQuery, words: String?) async -> (record: Data?, answered: Bool) {
        var replies: [Data] = []
        var answered = true
        let titles = [query.title] + [LRCLIBVersions.sameRecordingTitle(for: query.title)].compactMap { $0 }
        // Each title with the artist as given, then (a song by several) its lead artist alone.
        for artist in LRCLIBVersions.searchArtists(for: query.artist) {
          for title in titles {
            var components = URLComponents(string: "https://lrclib.net/api/search")!
            components.queryItems = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: artist),
            ]
            switch await send(components) {
            case .ok(let data): replies.append(data)
            case .notFound: break
            case .rateLimited, .offline, .failed: answered = false
            }
            if let record = LRCLIBVersions.bestRecord(in: replies, duration: query.duration, words: words) {
                return (record, true)
            }
          }
        }
        // Last: a plain text search ("title lead-artist"), which finds songs filed under another spelling or order of the
        // artists. The 2 s length check still keeps other songs out.
        let bare = LRCLIBVersions.searchTitles(for: query.title).last ?? query.title
        let lead = LRCLIBVersions.searchArtists(for: query.artist).last ?? query.artist
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [URLQueryItem(name: "q", value: "\(bare) \(lead)")]
        switch await send(components) {
        case .ok(let data): replies.append(data)
        case .notFound: break
        case .rateLimited, .offline, .failed: answered = false
        }
        if let record = LRCLIBVersions.bestRecord(in: replies, duration: query.duration, words: words) {
            return (record, true)
        }
        return (nil, answered)
    }

    /// Caches a record found by searching, and reads it like a lookup.
    private func keep(_ record: Data, for query: LyricsQuery) -> LyricsResult {
        writeCache(record, for: query, found: true)
        return LRCLIBReply.decode(record)
    }

    // MARK: - Your fixes

    public func offset(for query: LyricsQuery) async -> TimeInterval {
        readChoice(for: query)?.offset ?? 0
    }

    public func setOffset(_ offset: TimeInterval, for query: LyricsQuery) async {
        var choice = readChoice(for: query) ?? Choice()
        // Keep the lyrics this fix was made for; otherwise a cache clean-up could pair it with another version.
        if choice.record == nil { choice.record = cachedRecord(for: query) }
        choice.offset = offset
        writeChoice(choice, for: query)
    }

    public func versions(for query: LyricsQuery) async -> LyricsVersionsResult {
        let current = (readChoice(for: query)?.record ?? cachedRecord(for: query)).flatMap(LyricsVersion.init(record:))
        var replies: [Data] = []
        var problem: LyricsVersionsResult?
        // The title as given, then the bare title if it differs (at most two searches, only when you ask).
        for title in LRCLIBVersions.searchTitles(for: query.title) {
            var components = URLComponents(string: "https://lrclib.net/api/search")!
            components.queryItems = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: query.artist),
            ]
            switch await send(components) {
            case .ok(let data): replies.append(data)
            case .notFound: break
            case .rateLimited(let until): problem = problem ?? .rateLimited(until: until)
            case .offline: problem = problem ?? .offline
            case .failed(let reason): problem = problem ?? .failed(reason)
            }
        }
        if replies.isEmpty, let problem { return problem }
        guard let versions = LRCLIBVersions.decode(replies, duration: query.duration, current: current) else {
            return .failed("unreadable reply")
        }
        return .found(versions)
    }

    public func use(_ version: LyricsVersion, for query: LyricsQuery) async {
        writeChoice(Choice(offset: 0, record: version.record), for: query)
    }

    // MARK: - Network

    private enum Response {
        case ok(Data)
        case notFound
        case rateLimited(Date)
        case offline
        case failed(String)
    }

    /// LRCLIB is a free service and sometimes answers "busy" (503) or times out (seen 2026-10-30: popular songs like
    /// "Dog Days Are Over" ended as failed for good). A busy answer or a timeout is asked again, twice, 1.5 s then
    /// 4 s later; anything else counts at once.
    private func send(_ components: URLComponents) async -> Response {
        var answer = await sendOnce(components)
        for wait in [1.5, 4.0] {
            guard case .failed(let reason) = answer, reason.hasPrefix("LRCLIB answered 5") || reason == "timed out" else { break }
            try? await Task.sleep(for: .seconds(wait))
            if Task.isCancelled { break }
            answer = await sendOnce(components)
        }
        return answer
    }

    private func sendOnce(_ components: URLComponents) async -> Response {
        if let pausedUntil, pausedUntil > .now { return .rateLimited(pausedUntil) }
        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 200: return .ok(data)
            case 404: return .notFound
            case 429:
                let wait = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 60
                let until = Date.now.addingTimeInterval(wait)
                pausedUntil = until
                Log.app.notice("Lyrics: LRCLIB asked to slow down for \(Int(wait), privacy: .public) s")
                return .rateLimited(until)
            case let status:
                return .failed("LRCLIB answered \(status)")
            }
        } catch let error as URLError where Self.offlineCodes.contains(error.code) {
            return .offline
        } catch let error as URLError where error.code == .timedOut {
            return .failed("timed out")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
    ]

    // MARK: - Choices: <sha256>.json in Application Support, one per song you've fixed

    /// Your fix for one song: a timing offset, and the LRCLIB record it applies to.
    private struct Choice: Codable {
        var offset: TimeInterval = 0
        var record: Data?
    }

    private func readChoice(for query: LyricsQuery) -> Choice? {
        let url = choicesDirectory.appendingPathComponent(Self.fileName(for: query)).appendingPathExtension("json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Choice.self, from: data)
    }

    private func writeChoice(_ choice: Choice, for query: LyricsQuery) {
        try? FileManager.default.createDirectory(at: choicesDirectory, withIntermediateDirectories: true)
        let url = choicesDirectory.appendingPathComponent(Self.fileName(for: query)).appendingPathExtension("json")
        guard let data = try? JSONEncoder().encode(choice) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Cache: <sha256>.json holds LRCLIB's reply; <sha256>.none marks "not found" (its date is when)

    static func fileName(for query: LyricsQuery) -> String {
        SHA256.hash(data: Data(query.cacheKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// LRCLIB's reply for this song as cached, if any.
    private func cachedRecord(for query: LyricsQuery) -> Data? {
        try? Data(contentsOf: cacheDirectory.appendingPathComponent(Self.fileName(for: query)).appendingPathExtension("json"))
    }

    /// When the lead-artist search arrived (2026-10-29).
    static let leadArtistSearchSince = Date(timeIntervalSince1970: 1_794_292_000)  // + timed other cuts (0.30.2)  // also: another cut's words (0.28.1)

    private func readCache(for query: LyricsQuery) -> LyricsResult? {
        let base = cacheDirectory.appendingPathComponent(Self.fileName(for: query))
        let found = base.appendingPathExtension("json")
        if let data = try? Data(contentsOf: found) {
            // Words kept from another cut before 0.30.2, which now takes that cut's timing: look it up again.
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["lyricsfile"] is NSNull, object["syncedLyrics"] is NSNull, object["brimWordsOnly"] == nil {
                try? FileManager.default.removeItem(at: found)
                return nil
            }
            touch(found)  // most recently used: last to be evicted
            return LRCLIBReply.decode(data)
        }
        let none = base.appendingPathExtension("none")
        if let saved = modificationDate(none) {
            // A "none" from before the lead-artist search (0.22.1) gets one more try.
            if Date.now.timeIntervalSince(saved) < Self.notFoundLifetime, saved > Self.leadArtistSearchSince { return .notFound }
            try? FileManager.default.removeItem(at: none)
        }
        return nil
    }

    private func writeCache(_ data: Data, for query: LyricsQuery, found: Bool) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let url = cacheDirectory.appendingPathComponent(Self.fileName(for: query)).appendingPathExtension(found ? "json" : "none")
        try? data.write(to: url, options: .atomic)
        trimCache()
    }

    /// Keeps the cache under 5 MB by removing the least recently used entries.
    private func trimCache() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (url: URL, size: Int, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > Self.cacheLimit else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > Self.cacheLimit * 9 / 10 {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path)
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

import Foundation

/// The only facts about a song that leave your Mac: title, artist, album, and length (PRD §10).
public struct LyricsQuery: Hashable, Sendable {
    public var title: String
    public var artist: String
    public var album: String?
    public var duration: TimeInterval

    /// PRD F5: look up only when title, artist, and length are known and the song is under 15 minutes,
    /// which skips podcasts and long videos.
    public init?(_ item: NowPlaying) {
        guard !item.title.isEmpty, let artist = item.artist, !artist.isEmpty,
              let duration = item.duration, duration > 0, duration < 15 * 60 else { return nil }
        self.title = item.title
        self.artist = artist
        self.album = item.album
        self.duration = duration
    }

    public init(title: String, artist: String, album: String?, duration: TimeInterval) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }

    /// Same song, same album, same length (to the second) → same cache entry.
    public var cacheKey: String {
        "\(title.lowercased())|\(artist.lowercased())|\((album ?? "").lowercased())|\(Int(duration.rounded()))"
    }

    /// Still the song these lyrics are for, despite the noise players add when they announce it again
    /// (after Shuffle, an output switch, a pause): the same title and artist ignoring case, and a length within
    /// 2 s. A missing artist or length doesn't count against it. The album is ignored: macOS and a player's own
    /// announcement don't always agree on it. Your report, 2026-09-30: clicking Output or Shuffle sent the
    /// full-screen lyrics back to the top, because anything short of an exact match counted as a new song.
    public func isSameSong(as item: NowPlaying) -> Bool {
        guard Self.same(title, item.title) else { return false }
        if let artist = item.artist, !artist.isEmpty, !Self.same(self.artist, artist) { return false }
        if let length = item.duration, length > 0, abs(length - duration) > Self.lengthTolerance { return false }
        return true
    }

    /// Which details `item` announces differently (field names only, never the values, so they can be logged).
    public func differences(from item: NowPlaying) -> [String] {
        var fields: [String] = []
        if title != item.title { fields.append("title") }
        if artist != (item.artist ?? "") { fields.append("artist") }
        if album != item.album { fields.append("album") }
        if item.duration != duration { fields.append("length") }
        return fields
    }

    static let lengthTolerance: TimeInterval = 2

    private static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(b.trimmingCharacters(in: .whitespacesAndNewlines),
                     options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

/// What a lookup found.
public enum LyricsResult: Equatable, Sendable {
    case found(Lyrics)
    case notFound
    /// No internet (or LRCLIB unreachable). Tried again next time the song plays.
    case offline
    /// LRCLIB asked Brim to slow down: no more requests until this moment.
    case rateLimited(until: Date)
    case failed(String)
}

/// Finds lyrics for a song and keeps your per-song fixes. The live version is LRCLIB plus a disk cache;
/// tests use a fake.
public protocol LyricsService: Sendable {
    func lyrics(for query: LyricsQuery) async -> LyricsResult
    /// Your timing fix for this song in seconds (negative = lines earlier); 0 if you haven't changed it.
    func offset(for query: LyricsQuery) async -> TimeInterval
    /// Saves your timing fix. It also keeps the lyrics Brim has now for this song,
    /// so the fix can never end up on a different version later.
    func setOffset(_ offset: TimeInterval, for query: LyricsQuery) async
    /// The distinct timed versions LRCLIB has at this song's length, the one in use first.
    /// Asks LRCLIB only when you choose "Try Another Version".
    func versions(for query: LyricsQuery) async -> LyricsVersionsResult
    /// Uses `version` for this song from now on, with no timing fix.
    func use(_ version: LyricsVersion, for query: LyricsQuery) async
}

/// One upload of a song's timed lyrics on LRCLIB. Volunteers time them, so a song can have several that
/// disagree (checked 2026-09-29: "Easy" had one running 0.4 s late on average, up to 1.9 s).
public struct LyricsVersion: Equatable, Sendable {
    /// LRCLIB's id for this upload.
    public var id: Int
    public var lines: [LyricLine]
    /// LRCLIB's record as it came, so a chosen version is saved and read back exactly like a lookup.
    public var record: Data

    public init(id: Int, lines: [LyricLine], record: Data) {
        self.id = id
        self.lines = lines
        self.record = record
    }

    /// One LRCLIB record (an `/api/get` reply, or one entry of a search); nil without timed lines.
    public init?(record: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: record) as? [String: Any] else { return nil }
        self.init(object: object)
    }

    init?(object: [String: Any]) {
        guard let id = object["id"] as? Int,
              case let lines = LyricsFile.timedLines(synced: object["syncedLyrics"] as? String, file: object["lyricsfile"] as? String),
              !lines.isEmpty,
              let record = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        self.init(id: id, lines: lines, record: record)
    }

    /// Copies of one upload are common; they count as one version (every line within 0.05 s).
    public func hasSameTiming(as other: LyricsVersion) -> Bool {
        lines.count == other.lines.count && zip(lines, other.lines).allSatisfy { abs($0.time - $1.time) <= 0.05 }
    }
}

/// What asking LRCLIB for other versions found.
public enum LyricsVersionsResult: Equatable, Sendable {
    /// Distinct timings, the one in use first. One item means there's no other version.
    case found([LyricsVersion])
    case offline
    case rateLimited(until: Date)
    case failed(String)
}

/// LRCLIB's `/api/search` replies → the distinct timed versions. Pure, so it's unit-tested without the network.
public enum LRCLIBVersions {
    /// Titles to search: the player's title and, when it carries extras like "(with …)", "(feat. …)",
    /// "[From …]" or " - Remastered", the bare title too. Volunteers often upload under the bare title
    /// (checked on "Easy (with June Avery feat. Theo Marsh)": the 7 agreeing versions were titled "Easy").
    /// The length filter keeps other cuts out either way.
    public static func searchTitles(for title: String) -> [String] {
        var bare = title
        while let extra = bare.range(of: #"\s*[\(\[][^\(\)\[\]]*[\)\]]\s*$"#, options: .regularExpression) {
            bare.removeSubrange(extra)
        }
        if let suffix = bare.range(of: #"\s+-\s+.*$"#, options: .regularExpression) { bare.removeSubrange(suffix) }
        bare = bare.trimmingCharacters(in: .whitespaces)
        return bare.isEmpty || bare == title ? [title] : [title, bare]
    }

    /// Artists to search: the player's, and, for a song by several ("A & B", "A, B", "A feat. B", "A x B", "A with B"),
    /// the first alone: volunteers often upload under the lead artist (2026-10-29: Apple Music says "STELLA LEFTY &
    /// Bailey Zimmerman", LRCLIB has "My Kinda Love" under "STELLA LEFTY", synced).
    public static func searchArtists(for artist: String) -> [String] {
        let separators = [" & ", ", ", " feat. ", " feat ", " ft. ", " x ", " X ", " with ", " and "]
        var lead = artist
        for separator in separators {
            if let range = lead.range(of: separator, options: .caseInsensitive) { lead = String(lead[..<range.lowerBound]) }
        }
        lead = lead.trimmingCharacters(in: .whitespaces)
        return lead.isEmpty || lead == artist ? [artist] : [artist, lead]
    }

    /// For a song LRCLIB didn't find: the title without extras that keep the same recording
    /// ("- Remastered 2011", "[From Twisters: The Album]", "(Deluxe)", "Bonus Track", "Mono"/"Stereo").
    /// Never "(feat. …)", "(with …)", "Remix", "Live" or "Version": those can be another recording with
    /// other words, like the solo "Easy" and its remix. Nil when there's nothing safe to strip.
    public static func sameRecordingTitle(for title: String) -> String? {
        let extras = [
            #"\s*[\(\[](\d{4}\s+)?remaster(ed)?(\s+\d{4})?(\s+version)?[\)\]]\s*$"#,
            #"\s+-\s+(\d{4}\s+)?remaster(ed)?(\s+\d{4})?(\s+version)?\s*$"#,
            #"\s*[\(\[]from\s+[^\)\]]*[\)\]]\s*$"#,
            #"\s+-\s+from\s+.*$"#,
            #"\s*[\(\[](deluxe|bonus track|mono|stereo)[^\)\]]*[\)\]]\s*$"#,
            #"\s+-\s+(bonus track|mono|stereo)\s*$"#,
        ]
        var bare = title
        var changed = true
        while changed {
            changed = false
            for pattern in extras {
                if let range = bare.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                    bare.removeSubrange(range)
                    changed = true
                }
            }
        }
        bare = bare.trimmingCharacters(in: .whitespaces)
        return bare.isEmpty || bare == title ? nil : bare
    }

    /// From `/api/search` replies, a record for a song `/api/get` didn't find (or found only untimed):
    /// within 2 s of the length, timed lyrics first. With `words` (the untimed lyrics already found), a timed
    /// record counts only if at least 80% of its lines are those words; so it's the same song.
    public static func bestRecord(in replies: [Data], duration: TimeInterval, words: String? = nil) -> Data? {
        var untimed: Data?
        for reply in replies {
            guard let entries = try? JSONSerialization.jsonObject(with: reply) as? [[String: Any]] else { continue }
            for entry in entries {
                guard let length = entry["duration"] as? Double, abs(length - duration) <= 2,
                      let record = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { continue }
                if let version = LyricsVersion(object: entry) {
                    if let words, wordCoverage(of: version.lines, in: words) < 0.8 { continue }
                    return record
                }
                if words == nil, untimed == nil, (entry["plainLyrics"] as? String)?.isEmpty == false { untimed = record }
            }
        }
        return untimed ?? (words == nil ? wordsOfAnotherCut(in: replies, duration: duration) : nil)
    }

    /// Last resort: the same song in another cut, up to 10 s longer or shorter (Spotify's "You (Demo)" is 158 s,
    /// LRCLIB's 164 s; Apple Music's "Yaar Anmule" 271 s, LRCLIB's 276 s). The closest timed one is used as timed
    /// lyrics (your report, 2026-11-10: words without timing felt broken); a few seconds' gap is usually a longer intro
    /// or ending, and right-click → timing fixes it for good. With no timed one, only its words show, still.
    static func wordsOfAnotherCut(in replies: [Data], duration: TimeInterval) -> Data? {
        var timed: (gap: Double, record: Data)?
        var words: Data?
        for reply in replies {
            guard let entries = try? JSONSerialization.jsonObject(with: reply) as? [[String: Any]] else { continue }
            for entry in entries {
                guard let length = entry["duration"] as? Double, case let gap = abs(length - duration), gap <= 10 else { continue }
                let lines = LyricsFile.timedLines(synced: entry["syncedLyrics"] as? String, file: entry["lyricsfile"] as? String)
                if !lines.isEmpty, gap < (timed?.gap ?? .infinity),
                   let record = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) {
                    timed = (gap, record)
                }
                guard words == nil else { continue }
                let plain = (entry["plainLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? lines.map(\.text).joined(separator: "\n")
                guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                var untimed = entry
                untimed["syncedLyrics"] = NSNull()
                untimed["lyricsfile"] = NSNull()
                untimed["plainLyrics"] = plain
                untimed["brimWordsOnly"] = true  // made here; one saved before 0.30.2 is looked up again
                words = try? JSONSerialization.data(withJSONObject: untimed, options: [.sortedKeys])
            }
        }
        return timed?.record ?? words
    }

    /// Share of timed lines whose words appear (mostly) in some line of `text`.
    static func wordCoverage(of lines: [LyricLine], in text: String) -> Double {
        let wordLines = lines.filter { !$0.text.isEmpty }
        guard !wordLines.isEmpty else { return 0 }
        let reference = text.split(whereSeparator: \.isNewline).map { words(String($0)) }.filter { !$0.isEmpty }
        let found = wordLines.filter { line in
            let wanted = words(line.text)
            return reference.contains { similarity(wanted, $0) >= 0.6 }
        }
        return Double(found.count) / Double(wordLines.count)
    }

    /// Keeps versions within 2 s of the song's length (another cut of the song times differently: some
    /// were 20–30 s apart), folds exact copies together, and puts `current` first. The rest: versions with
    /// the same words, earliest to latest (so "lines feel late" means picking from the top), then versions
    /// where some lines differ, then other lyrics. Nil when no reply can be read.
    public static func decode(_ replies: [Data], duration: TimeInterval, current: LyricsVersion?) -> [LyricsVersion]? {
        var versions = current.map { [$0] } ?? []
        var readable = replies.isEmpty
        for reply in replies {
            guard let entries = try? JSONSerialization.jsonObject(with: reply) as? [[String: Any]] else { continue }
            readable = true
            for entry in entries {
                guard let length = entry["duration"] as? Double, abs(length - duration) <= 2,
                      let version = LyricsVersion(object: entry),
                      !versions.contains(where: { $0.id == version.id || $0.hasSameTiming(as: version) }) else { continue }
                versions.append(version)
            }
        }
        guard readable else { return nil }
        guard let current else { return versions }
        // Same words first (earliest to latest), then versions where some lines differ, then other lyrics.
        func group(_ comparison: Comparison) -> Int {
            comparison.coverage >= 0.9 ? 0 : comparison.coverage >= 0.5 ? 1 : 2
        }
        let rest = versions.dropFirst().enumerated()
            .map { (offset: $0.offset, version: $0.element, comparison: compare($0.element.lines, current.lines)) }
            .sorted { a, b in
                let (ga, gb) = (group(a.comparison), group(b.comparison))
                if ga != gb { return ga < gb }
                if let x = a.comparison.shift, let y = b.comparison.shift, x != y { return x < y }
                return a.offset < b.offset
            }
            .map(\.version)
        return [current] + rest
    }

    /// How version `a` compares with version `b`.
    public struct Comparison: Equatable, Sendable {
        /// Median time difference of the lines that match (negative: `a` is earlier). Nil with no matches.
        public var shift: TimeInterval?
        /// Share of `a`'s lines found in `b` (0…1). Below ~0.9 some lines are different words: often another
        /// recording (checked on "Easy": the solo song's uploads have a different second verse from the remix's).
        public var coverage: Double

        public init(shift: TimeInterval?, coverage: Double) {
            self.shift = shift
            self.coverage = coverage
        }
    }

    /// Matches each line of `a` to a line of `b` with mostly the same words (≥ 60% shared, so "darlin'" and
    /// "darling" match) within 5 s, keeping the order; a changed verse can't derail the lines after it.
    public static func compare(_ a: [LyricLine], _ b: [LyricLine]) -> Comparison {
        let wordLines = a.filter { !$0.text.isEmpty }
        let other = b.map { words($0.text) }
        var differences: [TimeInterval] = []
        var next = 0
        for line in wordLines {
            let wanted = words(line.text)
            guard !wanted.isEmpty, next < b.count else { continue }
            var best: (index: Int, score: Double)?
            for index in next..<b.count {
                if b[index].time > line.time + 5 { break }
                guard b[index].time >= line.time - 5 else { continue }
                let score = similarity(wanted, other[index])
                if score >= 0.6, score > (best?.score ?? 0) { best = (index, score) }
            }
            if let best {
                differences.append(line.time - b[best.index].time)
                next = best.index + 1
            }
        }
        let coverage = wordLines.isEmpty ? 0 : Double(differences.count) / Double(wordLines.count)
        return Comparison(shift: differences.isEmpty ? nil : differences.sorted()[differences.count / 2], coverage: coverage)
    }

    /// Share of words two lines have in common.
    static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    public static func decode(_ reply: Data, duration: TimeInterval, current: LyricsVersion?) -> [LyricsVersion]? {
        decode([reply], duration: duration, current: current)
    }
}

/// LRCLIB's `/api/get` reply → lyrics. Pure, so it's unit-tested without the network.
public enum LRCLIBReply {
    private struct Body: Decodable {
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
        var lyricsfile: String?
    }

    /// Timed lyrics win; plain words next; an empty or unreadable reply counts as not found.
    public static func decode(_ data: Data) -> LyricsResult {
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return .failed("unreadable reply") }
        if body.instrumental == true { return .found(.instrumental) }
        let lines = LyricsFile.timedLines(synced: body.syncedLyrics, file: body.lyricsfile)
        if !lines.isEmpty { return .found(.synced(lines)) }
        if let plain = body.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !plain.isEmpty {
            return .found(.plain(plain))
        }
        return .notFound
    }
}

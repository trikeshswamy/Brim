import Foundation

/// LRCLIB's newer `lyricsfile` (YAML): some songs keep their timing only here, with `syncedLyrics` empty (found
/// 2026-11-09 in your cache: 19 of 166 songs, many Punjabi, Hindi and Korean, showed as untimed words). Reads the
/// line list it keeps under `lines:`, each `- text:` with its `start_ms`; deeper entries (word timing) are skipped.
public enum LyricsFile {
    public static func lines(from file: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        var inLines = false
        var text: String?
        var start: Int?
        func flush() {
            if let text, let start { lines.append(LyricLine(time: TimeInterval(start) / 1000, text: text)) }
            text = nil
            start = nil
        }
        for raw in file.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("lines:") { inLines = true; continue }
            guard inLines else { continue }
            if let first = raw.first, first != " ", first != "-" { flush(); inLines = false; continue }  // the next key
            if raw.hasPrefix("- text:") {
                flush()
                text = scalar(raw.dropFirst("- text:".count))
            } else if raw.hasPrefix("  start_ms:") {
                start = Int(raw.dropFirst("  start_ms:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        flush()
        return lines.sorted { $0.time < $1.time }
    }

    /// A YAML scalar: bare, 'single-quoted' ('' is a quote) or "double-quoted" (JSON-like escapes).
    static func scalar(_ value: Substring) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.hasPrefix("'"), trimmed.hasSuffix("'") {
            return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\""),
           let data = trimmed.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        return trimmed
    }

    /// The timed lines of an LRCLIB record: `syncedLyrics` first, else `lyricsfile`.
    public static func timedLines(synced: String?, file: String?) -> [LyricLine] {
        if let synced, case let lines = LRCParser.parse(synced), !lines.isEmpty { return lines }
        return file.map(lines(from:)) ?? []
    }
}

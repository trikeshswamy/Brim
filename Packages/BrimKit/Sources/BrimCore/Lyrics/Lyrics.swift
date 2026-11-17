import Foundation

/// One timed lyric line. `time` is seconds from the start of the song, offset already applied.
public struct LyricLine: Equatable, Sendable {
    public var time: TimeInterval
    /// Empty for an instrumental gap (shown as a pause, not as text).
    public var text: String
    /// Real word timing, when the LRC has it (`<mm:ss.xx>` before each word): rare on LRCLIB. Empty: the sweep
    /// estimates (LyricSweep).
    public var marks: [WordMark]

    public init(time: TimeInterval, text: String, marks: [WordMark] = []) {
        self.time = time
        self.text = text
        self.marks = marks
    }
}

/// A word's start: the sweep reaches letter `letter` of the line at `time` (seconds from the song's start). A mark at
/// the line's end (`letter == text.count`) is when the last word finishes.
public struct WordMark: Equatable, Sendable {
    public var letter: Int
    public var time: TimeInterval

    public init(letter: Int, time: TimeInterval) {
        self.letter = letter
        self.time = time
    }
}

/// What LRCLIB (or the cache) has for a song.
public enum Lyrics: Equatable, Sendable {
    /// Timed lines, sorted by time: the lyrics follow the song.
    case synced([LyricLine])
    /// Words without timing: shown as a still block.
    case plain(String)
    /// The song has no words.
    case instrumental
}

public extension Lyrics {
    /// The line playing at `position` (the last line that has started), or nil before the first line.
    func currentLineIndex(at position: TimeInterval) -> Int? {
        guard case .synced(let lines) = self, !lines.isEmpty else { return nil }
        // Binary search: the first line that starts after `position`, minus one.
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].time <= position { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }

    /// When the next line starts after `position`; nil after the last line (nothing more to schedule).
    func nextLineTime(after position: TimeInterval) -> TimeInterval? {
        guard case .synced(let lines) = self else { return nil }
        return lines.first { $0.time > position }?.time
    }

    /// Every line moved by `seconds` (negative = earlier): your timing fix for a song. Order never changes.
    func shifted(by seconds: TimeInterval) -> Lyrics {
        guard seconds != 0, case .synced(let lines) = self else { return self }
        return .synced(lines.map { LyricLine(time: $0.time + seconds, text: $0.text, marks: $0.marks.moved(by: seconds)) })
    }
}

/// Reads LRC text: `[mm:ss]`, `[mm:ss.x]`, `[mm:ss.xx]`, `[mm:ss.xxx]`, several stamps on one line
/// (`[00:12.00][01:30.50]Chorus`), and the `[offset:±ms]` tag. Metadata tags (`[ar:]`, `[ti:]`, …) are skipped.
/// Lines come back sorted by time, with the offset applied (a positive offset shows lines earlier, per the LRC spec).
public enum LRCParser {
    public static func parse(_ text: String) -> [LyricLine] {
        var offset: TimeInterval = 0
        var lines: [LyricLine] = []

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var rest = Substring(rawLine).trimmingCharacters(in: .whitespaces)[...]
            var stamps: [TimeInterval] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let time = timestamp(tag) {
                    stamps.append(time)
                } else if tag.lowercased().hasPrefix("offset:"),
                          let milliseconds = Double(tag.dropFirst("offset:".count).trimmingCharacters(in: .whitespaces)) {
                    offset = milliseconds / 1000
                }
                rest = rest[rest.index(after: close)...]
            }
            let (words, marks) = wordTiming(rest)
            for stamp in stamps {
                // Word times belong to the first stamp; a repeat (a chorus) moves them along with it.
                lines.append(LyricLine(time: stamp, text: words, marks: marks.moved(by: stamp - (stamps.first ?? stamp))))
            }
        }
        return lines
            .map { LyricLine(time: max(0, $0.time - offset), text: $0.text, marks: $0.marks.moved(by: -offset)) }
            .sorted { $0.time < $1.time }
    }

    /// Enhanced LRC: `<mm:ss.xx>` tags inside a line time its words. Returns the line without them (before, the tags
    /// showed as text) and where each tag falls in it.
    static func wordTiming(_ rest: Substring) -> (text: String, marks: [WordMark]) {
        var clean = ""
        var marks: [WordMark] = []
        var rest = rest
        while let open = rest.firstIndex(of: "<") {
            clean += rest[..<open]
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: ">"), let time = timestamp(after[..<close]) {
                marks.append(WordMark(letter: clean.count, time: time))
                rest = after[after.index(after: close)...]
            } else {
                clean.append("<")
                rest = after
            }
        }
        clean += rest
        let lead = clean.prefix { $0.isWhitespace }.count
        let text = clean.trimmingCharacters(in: .whitespaces)
        let placed = marks.map { WordMark(letter: min(max($0.letter - lead, 0), text.count), time: $0.time) }
        // Only a usable timing: at least two marks, in order.
        guard placed.count >= 2, zip(placed, placed.dropFirst()).allSatisfy({ $0.time <= $1.time && $0.letter <= $1.letter })
        else { return (text, []) }
        return (text, placed)
    }

    /// `mm:ss`, `mm:ss.x`, `mm:ss.xx`, `mm:ss.xxx` → seconds. Anything else (e.g. `ar:Artist`) → nil.
    static func timestamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let minutes = Int(parts[0]), minutes >= 0,
              let seconds = Double(parts[1]), seconds >= 0, seconds < 60,
              parts[1].first?.isNumber == true else { return nil }
        return TimeInterval(minutes * 60) + seconds
    }
}

extension [WordMark] {
    func moved(by seconds: TimeInterval) -> [WordMark] {
        seconds == 0 ? self : map { WordMark(letter: $0.letter, time: Swift.max(0, $0.time + seconds)) }
    }
}

import Foundation

/// The word-by-word sweep across the current lyric line (prototype, your pick 2026-09-30).
///
/// LRCLIB mostly gives a time per line, not per word (0 of your 57 songs had word timing), so this estimates (a song
/// that has word timing follows it instead, `timed`, your pick 2026-10-29):
/// the letters light up at an even pace from the line's start, finishing a little before the next line.
/// A long pause after a line doesn't stretch it: it never goes slower than 5 letters a second.
public enum LyricSweep {
    /// How long the sweep across a line takes.
    public static func duration(start: TimeInterval, nextStart: TimeInterval, letters: Int) -> TimeInterval {
        let gap = max(nextStart - start, 0.3)
        return min(gap * 0.9, max(Double(letters) / 5, 1))
    }

    /// 0 … 1: how far through the line the singing is at `position`.
    public static func progress(position: TimeInterval, start: TimeInterval, nextStart: TimeInterval,
                                letters: Int) -> Double {
        let length = duration(start: start, nextStart: nextStart, letters: letters)
        return min(max((position - start) / length, 0), 1)
    }

    /// With real word timing: how far through the line (0 … 1) at `position`, the time to cross the whole line at
    /// the pace of the word being sung (huge while it holds still), and when that pace changes (nil: it doesn't).
    /// Between marks the front moves evenly through the letters; before the first it waits at the line's start;
    /// after the last word starts it finishes like the estimate does, unless an end mark says when.
    public static func timed(marks: [WordMark], letters: Int, start: TimeInterval, nextStart: TimeInterval,
                             position: TimeInterval) -> (progress: Double, duration: TimeInterval, until: TimeInterval?) {
        guard letters > 0, let first = marks.first, let last = marks.last else { return (0, hold, nil) }
        var points = marks.map { (time: $0.time, share: Double($0.letter) / Double(letters)) }
        if first.letter > 0 { points.insert((start, 0), at: 0) }
        if last.letter < letters {
            let rest = letters - last.letter
            let end = last.time + duration(start: last.time, nextStart: max(nextStart, last.time + 0.3), letters: rest)
            points.append((end, 1))
        }
        guard position >= points[0].time else { return (points[0].share, hold, points[0].time) }
        for (from, to) in zip(points, points.dropFirst()) where position < to.time {
            let pace = (to.share - from.share) / max(to.time - from.time, 0.001)
            let progress = from.share + (position - from.time) * pace
            return (min(max(progress, 0), 1), pace > 0 ? 1 / pace : hold, to.time)
        }
        return (points.last?.share ?? 1, hold, nil)
    }

    /// The pace of a sweep that isn't moving: a line takes days to cross.
    static let hold: TimeInterval = 1_000_000
}

/// The sweep's timing for the current line, for Core Animation to play (rebuilt 2026-09-30: the first
/// version redrew text 30 times a second and cost 19% CPU). It changes only when the line changes, the song
/// pauses or plays, or jumps, so views update rarely and the moving part costs Brim nothing per frame.
public struct SweepClock: Equatable, Sendable {
    public var line: Int
    /// How far through the line (0 … 1) at `anchor`.
    public var progress: Double
    public var anchor: Date
    /// The whole sweep's length in seconds (see `LyricSweep.duration`).
    public var duration: TimeInterval
    public var playing: Bool

    public init(line: Int, progress: Double, anchor: Date, duration: TimeInterval, playing: Bool) {
        self.line = line
        self.progress = progress
        self.anchor = anchor
        self.duration = duration
        self.playing = playing
    }

    public func progress(at date: Date) -> Double {
        guard playing, duration > 0 else { return progress }
        return min(max(progress + date.timeIntervalSince(anchor) / duration, 0), 1)
    }

    /// The rest of this sweep, starting over from the first letter at `date` and ending when it would have (at least
    /// 0.3 s). A line that arrives into place partway through its time sweeps from its start then, instead of
    /// showing letters already lit (your check, 2026-10-01).
    public func startingNow(_ date: Date = .now) -> SweepClock {
        let left = duration * (1 - progress(at: date))
        return SweepClock(line: line, progress: 0, anchor: date, duration: max(left, 0.3), playing: playing)
    }
}

/// Finds the visual lines of rendered text: bands of pixel rows with ink. Rects are in pixels, top-left origin.
public enum SweepBands {
    /// `alpha` is row-major, top row first. A band ends after more than `maxGap` blank rows; a band much
    /// shorter than the tallest (an "i" dot on its own row) joins the band below it.
    public static func detect(alpha: [UInt8], width: Int, height: Int, threshold: UInt8 = 24, maxGap: Int = 3) -> [CGRect] {
        guard width > 0, height > 0, alpha.count >= width * height else { return [] }
        var bands: [CGRect] = []
        var top: Int?
        var bottom = 0, left = Int.max, right = -1, blank = 0
        func close() {
            if let top { bands.append(CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)) }
            top = nil
            left = .max
            right = -1
        }
        for y in 0..<height {
            var rowLeft = Int.max, rowRight = -1
            let start = y * width
            for x in 0..<width where alpha[start + x] > threshold {
                rowLeft = min(rowLeft, x)
                rowRight = x
            }
            if rowRight >= 0 {
                if top == nil { top = y }
                bottom = y
                left = min(left, rowLeft)
                right = max(right, rowRight)
                blank = 0
            } else if top != nil {
                blank += 1
                if blank > maxGap {
                    close()
                    blank = 0
                }
            }
        }
        close()
        // Stray bits (a dot above a line) belong to the line below them.
        let tallest = bands.map(\.height).max() ?? 0
        var merged: [CGRect] = []
        var pending: CGRect?
        for band in bands {
            if band.height < tallest * 0.35 {
                pending = pending.map { $0.union(band) } ?? band
                continue
            }
            merged.append(pending.map { $0.union(band) } ?? band)
            pending = nil
        }
        if let pending { merged.append(merged.popLast().map { $0.union(pending) } ?? pending) }
        return merged
    }
}

/// One visual line's part of the sweep: where its lit front is now, where it ends, and (while playing)
/// when it starts moving and for how long.
public struct SweepStep: Equatable, Sendable {
    /// X of the lit front now; the line is dark left of `band.minX` and fully lit at `to`.
    public var from: CGFloat
    public var to: CGFloat
    /// Seconds from now until this line's front starts moving (nil: it doesn't move, e.g. paused or done).
    public var delay: TimeInterval?
    public var duration: TimeInterval
}

public enum SweepPlan {
    /// Reading order: the front crosses each line left to right (plus a soft edge `edge` wide), then the
    /// next line, at one even speed for the whole sweep.
    public static func steps(for bands: [CGRect], edge: CGFloat, clock: SweepClock, at date: Date) -> [SweepStep] {
        let lengths = bands.map { $0.width + edge }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return [] }
        let reached = CGFloat(clock.progress(at: date)) * total
        let speed = total / CGFloat(max(clock.duration, 0.01))  // points per second
        var start: CGFloat = 0
        return zip(bands, lengths).map { band, length in
            defer { start += length }
            let travelled = min(max(reached - start, 0), length)
            let moving = clock.playing && travelled < length
            return SweepStep(from: band.minX + travelled, to: band.minX + length,
                             delay: moving ? TimeInterval(max(0, (start - reached) / speed)) : nil,
                             duration: moving ? TimeInterval((length - travelled) / speed) : 0)
        }
    }
}

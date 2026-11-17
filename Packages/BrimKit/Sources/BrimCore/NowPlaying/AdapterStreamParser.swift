import Foundation

/// Turns the helper's `stream --micros` output into `NowPlaying` values.
///
/// The helper prints one JSON line per change. When the item changes it sends every field
/// (`"diff": false`); after that only the fields that changed (`"diff": true`, where `null`
/// means "removed"). So the parser keeps the merged fields between lines.
/// Use one parser per stream, from one task. It is not thread-safe.
public final class AdapterStreamParser {
    public enum Result: Equatable, Sendable {
        case item(NowPlaying)
        case nothingPlaying
        /// Not a data line (or not JSON). Nothing changed.
        case ignored
    }

    private var fields: [String: Any] = [:]
    private var artwork: Data?

    public init() {}

    public func consume(line: String) -> Result {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "data"
        else { return .ignored }

        let payload = object["payload"] as? [String: Any] ?? [:]
        let isDiff = object["diff"] as? Bool == true
        if isDiff {
            for (key, value) in payload {
                if value is NSNull { fields.removeValue(forKey: key) } else { fields[key] = value }
            }
        } else {
            fields = payload
        }

        // Artwork is big (100–200 KB of base64). Decode it only when this line carries it.
        if !isDiff || payload.keys.contains("artworkData") {
            artwork = (fields["artworkData"] as? String).flatMap { Data(base64Encoded: $0) }
        }

        guard let item = snapshot() else { return .nothingPlaying }
        return .item(item)
    }

    private func snapshot() -> NowPlaying? {
        guard let title = fields["title"] as? String, !title.isEmpty else { return nil }
        func seconds(_ key: String) -> TimeInterval? {
            (fields[key] as? NSNumber).map { $0.doubleValue / 1_000_000 }
        }
        return NowPlaying(
            title: title,
            artist: fields["artist"] as? String,
            album: fields["album"] as? String,
            bundleIdentifier: fields["bundleIdentifier"] as? String,
            parentBundleIdentifier: fields["parentApplicationBundleIdentifier"] as? String,
            isPlaying: fields["playing"] as? Bool ?? false,
            duration: seconds("durationMicros"),
            elapsed: seconds("elapsedTimeMicros"),
            timestamp: seconds("timestampEpochMicros").map { Date(timeIntervalSince1970: $0) },
            playbackRate: (fields["playbackRate"] as? NSNumber)?.doubleValue,
            artwork: artwork,
            mediaType: fields["mediaType"] as? String
        )
    }
}

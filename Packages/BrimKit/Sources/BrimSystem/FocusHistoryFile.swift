import Foundation
import BrimCore

/// Focus history on your Mac: one JSON line per session in `~/Library/Application Support/Brim/focus-history.jsonl`.
/// Never sent anywhere. Appending a line can't damage the ones before it; a line that can't be read is skipped.
public actor FocusHistoryFile: FocusHistoryService {
    private let url: URL

    public init(url: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.url = url ?? support.appendingPathComponent("Brim/focus-history.jsonl")
    }

    public func load() async -> [FocusSession] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(FocusSession.self, from: Data($0.utf8)) }
    }

    public func append(_ session: FocusSession) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(session) else { return }
        let line = data + Data("\n".utf8)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
        } catch {
            Log.app.error("Focus history couldn't be saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}

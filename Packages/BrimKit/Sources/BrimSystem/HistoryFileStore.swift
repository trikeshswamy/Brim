import Foundation
import BrimCore

/// History on your Mac only: `~/Library/Application Support/Brim/history.json`, written whole after each song.
public struct HistoryFileStore: HistoryFile {
    private let url: URL

    public init(url: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.url = url ?? support.appendingPathComponent("Brim/history.json")
    }

    public func load() -> [String: [HistoryEntry]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: [HistoryEntry]].self, from: data)) ?? [:]
    }

    public func save(_ history: [String: [HistoryEntry]]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

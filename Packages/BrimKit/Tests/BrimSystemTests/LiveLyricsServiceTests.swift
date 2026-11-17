import Foundation
import Testing
@testable import BrimCore
@testable import BrimSystem

/// Your per-song fixes, on disk (temporary folders; no network).
struct LiveLyricsServiceTests {
    private let query = LyricsQuery(title: "Easy", artist: "Sam Rowe", album: "Easy", duration: 214)
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("brim-tests-\(UUID().uuidString)")
    private var cache: URL { root.appendingPathComponent("cache") }

    private func makeService() -> LiveLyricsService {
        LiveLyricsService(userAgent: "Brim tests", session: .shared,
                          cacheDirectory: cache, choicesDirectory: root.appendingPathComponent("choices"))
    }

    private func cacheReply(_ json: String) throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let file = cache.appendingPathComponent(LiveLyricsService.fileName(for: query)).appendingPathExtension("json")
        try Data(json.utf8).write(to: file)
    }

    @Test func aFixKeepsItsLyricsWhenTheCacheIsCleared() async throws {
        try cacheReply(#"{"id": 7, "syncedLyrics": "[00:05.00] a\n[00:10.00] b"}"#)
        let service = makeService()
        #expect(await service.offset(for: query) == 0)
        await service.setOffset(-0.5, for: query)
        try FileManager.default.removeItem(at: cache)   // macOS or the 5 MB limit clears the cache
        #expect(await service.offset(for: query) == -0.5)
        #expect(await service.lyrics(for: query) == .found(.synced([LyricLine(time: 5, text: "a"), LyricLine(time: 10, text: "b")])))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func choosingAVersionUsesItAndResetsTheFix() async throws {
        try cacheReply(#"{"id": 7, "syncedLyrics": "[00:05.00] a"}"#)
        let service = makeService()
        await service.setOffset(1, for: query)
        let other = try #require(LyricsVersion(record: Data(#"{"id": 8, "syncedLyrics": "[00:04.00] a"}"#.utf8)))
        await service.use(other, for: query)
        #expect(await service.offset(for: query) == 0)
        #expect(await service.lyrics(for: query) == .found(.synced([LyricLine(time: 4, text: "a")])))
        try? FileManager.default.removeItem(at: root)
    }
}

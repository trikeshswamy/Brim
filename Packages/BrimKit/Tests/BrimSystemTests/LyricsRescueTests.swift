import Foundation
import Testing
@testable import BrimCore
@testable import BrimSystem

/// Stands in for lrclib.net: answers by path and track name, and counts requests.
nonisolated final class StubLRCLIB: URLProtocol {
    nonisolated(unsafe) static var answers: [String: (status: Int, body: String)] = [:]
    nonisolated(unsafe) static var requests: [String] = []

    static func key(_ path: String, _ title: String) -> String { "\(path)|\(title)" }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "lrclib.net" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let title = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "track_name" }?.value ?? ""
        let key = Self.key(url.path, title)
        Self.requests.append(key)
        let answer = Self.answers[key] ?? (404, #"{"message":"not found"}"#)
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: nil,
                                       headerFields: answer.status == 429 ? ["Retry-After": "0"] : nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct LyricsRescueTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("brim-rescue-\(UUID().uuidString)")

    private func makeService() -> LiveLyricsService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubLRCLIB.self]
        return LiveLyricsService(userAgent: "Brim tests", session: URLSession(configuration: configuration),
                                 cacheDirectory: root.appendingPathComponent("cache"),
                                 choicesDirectory: root.appendingPathComponent("choices"))
    }
    private func query(_ title: String) -> LyricsQuery { LyricsQuery(title: title, artist: "Artist", album: "Album", duration: 200) }
    private let timed = #"[{"id": 7, "duration": 200.0, "syncedLyrics": "[00:05.00] hello there\n[00:09.00] second line"}]"#

    @Test func aMissIsRescuedBySearchAndCached() async {
        StubLRCLIB.requests = []
        StubLRCLIB.answers = [StubLRCLIB.key("/api/search", "Dog Days - 2010 Remaster"): (200, "[]"),
                              StubLRCLIB.key("/api/search", "Dog Days"): (200, timed)]
        let service = makeService()
        let result = await service.lyrics(for: query("Dog Days - 2010 Remaster"))
        #expect(result == .found(.synced([LyricLine(time: 5, text: "hello there"), LyricLine(time: 9, text: "second line")])))
        #expect(await service.currentCounters().rescued == 1)
        _ = await service.lyrics(for: query("Dog Days - 2010 Remaster"))   // now from the cache
        #expect(StubLRCLIB.requests.count == 3)                             // get, search, search; nothing more
        try? FileManager.default.removeItem(at: root)
    }

    @Test func aRealMissIsRemembered() async {
        StubLRCLIB.requests = []
        StubLRCLIB.answers = [StubLRCLIB.key("/api/search", "Nowhere"): (200, "[]")]
        let service = makeService()
        #expect(await service.lyrics(for: query("Nowhere")) == .notFound)
        _ = await service.lyrics(for: query("Nowhere"))
        #expect(StubLRCLIB.requests.count == 3)                             // get, search, text search; then the cache
        try? FileManager.default.removeItem(at: root)
    }

    @Test func aMissWhoseSearchCouldntAnswerIsAskedAgain() async {
        StubLRCLIB.requests = []
        StubLRCLIB.answers = [StubLRCLIB.key("/api/search", "Busy"): (429, "{}")]
        let service = makeService()
        #expect(await service.lyrics(for: query("Busy")) == .notFound)
        StubLRCLIB.answers = [StubLRCLIB.key("/api/search", "Busy"): (200, timed)]
        try? await Task.sleep(for: .milliseconds(50))                       // Retry-After: 0
        let second = await service.lyrics(for: query("Busy"))
        #expect(second != .notFound)                                        // not remembered as "not found"
        try? FileManager.default.removeItem(at: root)
    }

    @Test func untimedLyricsBecomeTimedOnlyWithTheSameWords() async {
        StubLRCLIB.requests = []
        StubLRCLIB.answers = [
            StubLRCLIB.key("/api/get", "Plain"): (200, #"{"id": 2, "duration": 200.0, "plainLyrics": "hello there\nsecond line"}"#),
            StubLRCLIB.key("/api/search", "Plain"): (200, timed),
            StubLRCLIB.key("/api/get", "Other"): (200, #"{"id": 3, "duration": 200.0, "plainLyrics": "totally different\nwords here"}"#),
            StubLRCLIB.key("/api/search", "Other"): (200, timed),
        ]
        let service = makeService()
        guard case .found(.synced)? = Optional(await service.lyrics(for: query("Plain"))) else {
            Issue.record("expected timed lyrics"); return
        }
        #expect(await service.lyrics(for: query("Other")) == .found(.plain("totally different\nwords here")))
        #expect(await service.currentCounters().madeTimed == 1)
        try? FileManager.default.removeItem(at: root)
    }
}

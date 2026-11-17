import Foundation
import Testing
@testable import BrimCore

/// The Safari fallback looks at Safari only with a reason (2026-10-26: a full look cost 3–7 s every second).
struct SafariFallbackRulesTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func silentOrClosedSafariIsNeverLookedAt() {
        #expect(!SafariFallbackRules.shouldLook(safariRunning: true, webAudioPlaying: false, lastHeard: nil, now: now))
        #expect(!SafariFallbackRules.shouldLook(safariRunning: false, webAudioPlaying: true, lastHeard: now, now: now))
    }

    @Test func soundAndTheMinuteAfterIt() {
        #expect(SafariFallbackRules.shouldLook(safariRunning: true, webAudioPlaying: true, lastHeard: nil, now: now))
        let paused = now.addingTimeInterval(-59)
        #expect(SafariFallbackRules.shouldLook(safariRunning: true, webAudioPlaying: false, lastHeard: paused, now: now))
        let long = now.addingTimeInterval(-61)
        #expect(!SafariFallbackRules.shouldLook(safariRunning: true, webAudioPlaying: false, lastHeard: long, now: now))
        #expect(SafariFallbackRules.interval(webAudioPlaying: true) == 1)
        #expect(SafariFallbackRules.interval(webAudioPlaying: false) == 2)
    }
}

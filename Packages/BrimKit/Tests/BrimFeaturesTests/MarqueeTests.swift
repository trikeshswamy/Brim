import Testing
@testable import BrimFeatures

/// The looping marquee's timing, as measured from your video of Apple Music (2026-10-29).
struct MarqueeTests {
    @Test func textThatFitsNeverMoves() {
        #expect(!MarqueePlan.scrolls(overflow: 0))
        #expect(!MarqueePlan.scrolls(overflow: 1.5))  // a sliver isn't worth moving for
        #expect(MarqueePlan.scrolls(overflow: 2))
    }

    @Test func aGlideIs30PointsASecondPlusHalfASecondOfEasing() {
        let glide = MarqueePlan.glide(distance: 300)  // the text plus the gap
        #expect(glide.duration == 10.5)
        #expect(abs(glide.ease - 0.5 / 10.5) < 0.0001)
        // A very short glide never eases for more than 45% at each end.
        #expect(MarqueePlan.glide(distance: 3).ease == 0.45)
    }

    @Test func itRestsLikeApplesBetweenLoops() {
        #expect(MarqueePlan.rest == 3.5)
        #expect(MarqueePlan.firstRest < MarqueePlan.rest)
    }

    @Test func thePillGlidesOncePerSong() {
        let song = "pill|test-\(Int.random(in: 0...1_000_000))"
        #expect(MarqueeMemory.firstTime(song))
        #expect(MarqueeMemory.firstTime(song) == false)  // back after a HUD: stays still
        #expect(MarqueeMemory.firstTime(song + "|next"))  // a new song glides again
    }
}

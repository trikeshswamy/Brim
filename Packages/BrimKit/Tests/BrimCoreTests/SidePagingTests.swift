import Testing
@testable import BrimCore

/// The pair beside the controls follows your fingers (your pick, 2026-11-16).
struct SidePagingTests {
    @Test func fingersMovingLeftBringTheRightPageIn() {
        #expect(SidePaging.position(page: 0, fingerDX: 0) == 0)
        #expect(SidePaging.position(page: 0, fingerDX: -45) == 0.5)
        #expect(SidePaging.position(page: 1, fingerDX: 45) == 0.5)
        #expect(SidePaging.position(page: 0, fingerDX: -90) == 1)
    }

    @Test func pullingPastTheLastPageGivesALittleAndStops() {
        let pulled = SidePaging.position(page: 0, fingerDX: 90)
        #expect(pulled < 0 && pulled > -SidePaging.stretch)
        let far = SidePaging.position(page: 0, fingerDX: 900)
        #expect(far < pulled && far > -SidePaging.stretch)       // harder the further
        let beyond = SidePaging.position(page: 1, fingerDX: -90)
        #expect(beyond > 1 && beyond < 1 + SidePaging.stretch)
    }

    @Test func itLandsPastHalfwayOrOnAFlick() {
        #expect(SidePaging.landing(page: 0, position: 0.6, velocity: 0) == 1)
        #expect(SidePaging.landing(page: 0, position: 0.4, velocity: 0) == 0)      // springs back
        #expect(SidePaging.landing(page: 0, position: 0.2, velocity: -500) == 1)   // a quick flick to the left
        #expect(SidePaging.landing(page: 0, position: 0.05, velocity: -500) == 0)  // too small to count
        #expect(SidePaging.landing(page: 0, position: 0.2, velocity: 500) == 0)    // a flick the other way
        #expect(SidePaging.landing(page: 1, position: 0.3, velocity: 0) == 0)
        #expect(SidePaging.landing(page: 0, position: -0.1, velocity: 600) == 0)   // pulled past the edge
    }

    @Test func eachPageFadesWithDistance() {
        #expect(SidePaging.visibility(of: 0, at: 0) == 1)
        #expect(SidePaging.visibility(of: 1, at: 0.25) == 0.25)
        #expect(SidePaging.visibility(of: 1, at: -0.1) == 0)
    }
}

import XCTest
@testable import Hassonic

final class PlaybackProgressTests: XCTestCase {

    // MARK: - Helpers

    private func anchor(position: Double = 60, secondsAgo: Double = 0, duration: Double = 300) -> (Double, Date?, String, Double, Date) {
        let anchorDate = secondsAgo == 0 ? Date() : Date(timeIntervalSinceNow: -secondsAgo)
        return (position, anchorDate, "playing", duration, Date())
    }

    // MARK: - Interpolation while playing

    func testInterpolatesElapsedTimeWhenPlaying() {
        let anchorDate = Date(timeIntervalSinceNow: -10)
        let now = Date()
        let result = playbackElapsed(anchorPosition: 60, anchorDate: anchorDate, state: "playing", duration: 300, now: now)
        XCTAssertEqual(result, 70, accuracy: 0.1)
    }

    func testReturnsAnchorPositionWhenAnchorDateNil() {
        let result = playbackElapsed(anchorPosition: 60, anchorDate: nil, state: "playing", duration: 300, now: Date())
        XCTAssertEqual(result, 60)
    }

    // MARK: - Clamping

    func testClampsToZeroWhenAnchorNegative() {
        let result = playbackElapsed(anchorPosition: -5, anchorDate: nil, state: "paused", duration: 300, now: Date())
        XCTAssertEqual(result, 0)
    }

    func testClampsToZeroWhenInterpolationGoesNegative() {
        // anchor 2 s in, but wall-clock went back somehow (shouldn't happen, but must not crash)
        let anchorDate = Date(timeIntervalSinceNow: 5) // anchor set 5 s in the future
        let result = playbackElapsed(anchorPosition: 2, anchorDate: anchorDate, state: "playing", duration: 300, now: Date())
        XCTAssertEqual(result, 0)
    }

    func testClampsAtDuration() {
        let anchorDate = Date(timeIntervalSinceNow: -1000)
        let result = playbackElapsed(anchorPosition: 290, anchorDate: anchorDate, state: "playing", duration: 300, now: Date())
        XCTAssertEqual(result, 300)
    }

    func testAnchorPositionClampedAtDurationWhenExceedsIt() {
        let result = playbackElapsed(anchorPosition: 400, anchorDate: nil, state: "paused", duration: 300, now: Date())
        XCTAssertEqual(result, 300)
    }

    // MARK: - Paused / stopped state

    func testFreezeAtAnchorWhenPaused() {
        let anchorDate = Date(timeIntervalSinceNow: -30)
        let result = playbackElapsed(anchorPosition: 60, anchorDate: anchorDate, state: "paused", duration: 300, now: Date())
        XCTAssertEqual(result, 60)
    }

    func testFreezeAtAnchorWhenStopped() {
        let anchorDate = Date(timeIntervalSinceNow: -30)
        let result = playbackElapsed(anchorPosition: 60, anchorDate: anchorDate, state: "stopped", duration: 300, now: Date())
        XCTAssertEqual(result, 60)
    }

    func testFreezeAtAnchorWhenOff() {
        let anchorDate = Date(timeIntervalSinceNow: -30)
        let result = playbackElapsed(anchorPosition: 60, anchorDate: anchorDate, state: "off", duration: 300, now: Date())
        XCTAssertEqual(result, 60)
    }

    // MARK: - Drift correction (new anchor re-anchors correctly)

    func testDriftCorrectionOnNewAnchor() {
        // Simulate: was interpolating to ~70, HA now sends position=75 with a fresh timestamp
        let freshAnchorDate = Date(timeIntervalSinceNow: -2)
        let result = playbackElapsed(anchorPosition: 75, anchorDate: freshAnchorDate, state: "playing", duration: 300, now: Date())
        XCTAssertEqual(result, 77, accuracy: 0.2)
    }

    // MARK: - Duration change

    func testClampedAfterDurationShrinks() {
        // Track switched mid-play; new duration shorter than current position
        let anchorDate = Date(timeIntervalSinceNow: -5)
        let result = playbackElapsed(anchorPosition: 10, anchorDate: anchorDate, state: "playing", duration: 12, now: Date())
        XCTAssertEqual(result, 12)
    }

    // MARK: - Client-side ticking

    func testClientTickAdvancesWhilePlaying() {
        let result = advancePlaybackElapsed(
            current: 60,
            state: "playing",
            duration: 300,
            elapsedTime: 1
        )
        XCTAssertEqual(result, 61)
    }

    func testClientTickUsesActualElapsedTime() {
        let result = advancePlaybackElapsed(
            current: 60,
            state: "playing",
            duration: 300,
            elapsedTime: 2.5
        )
        XCTAssertEqual(result, 62.5)
    }

    func testClientTickFreezesWhilePaused() {
        let result = advancePlaybackElapsed(
            current: 60,
            state: "paused",
            duration: 300,
            elapsedTime: 1
        )
        XCTAssertEqual(result, 60)
    }

    func testClientTickClampsAtDuration() {
        let result = advancePlaybackElapsed(
            current: 299.5,
            state: "playing",
            duration: 300,
            elapsedTime: 1
        )
        XCTAssertEqual(result, 300)
    }
}

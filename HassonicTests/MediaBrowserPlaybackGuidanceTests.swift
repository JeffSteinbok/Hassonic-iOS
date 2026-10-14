import XCTest
@testable import Hassonic

/// When a failed browse asks the person to play something first, and when it
/// shows the real error instead.
final class MediaBrowserPlaybackGuidanceTests: XCTestCase {

    private func error(_ message: String, code: String? = nil) -> HAResultError {
        HAResultError(code: code.map(JSONValue.string), message: message)
    }

    func testAFailureWhileIdleAsksForPlayback() {
        for state in ["idle", "off", "stopped", "unavailable", "unknown"] {
            XCTAssertTrue(MediaBrowseFailure.needsPlayback(playerState: state, error: error("Not found")), state)
        }
    }

    func testAFailureWhilePlayingOrPausedShowsTheError() {
        XCTAssertFalse(MediaBrowseFailure.needsPlayback(playerState: "playing", error: error("Not found")))
        XCTAssertFalse(MediaBrowseFailure.needsPlayback(playerState: "paused", error: error("Not found")))
    }

    func testAnUnknownPlayerShowsTheError() {
        XCTAssertFalse(MediaBrowseFailure.needsPlayback(playerState: nil, error: error("Not found")))
    }

    func testAuthAndConnectionErrorsShowEvenWhileIdle() {
        XCTAssertFalse(MediaBrowseFailure.needsPlayback(playerState: "idle", error: error("Invalid authentication credentials")))
        XCTAssertFalse(MediaBrowseFailure.needsPlayback(playerState: "idle", error: error("Denied", code: "unauthorized")))
        XCTAssertFalse(MediaBrowseFailure.needsPlayback(playerState: "idle", error: error("Lost the connection to Home Assistant")))
        XCTAssertFalse(MediaBrowseFailure.needsPlayback(playerState: "idle", error: error("No connection to Home Assistant")))
    }
}

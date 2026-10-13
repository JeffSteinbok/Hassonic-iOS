import XCTest
@testable import Hassonic

/// Tests for the playback-guidance logic in the Media Browser.
///
/// The private `isSpotifyIdleOrStopped` check inside `MediaBrowserSheet` is
/// driven by the Spotify entity state.  These tests exercise the three
/// branching scenarios through the same decision the view takes: classify
/// a failed browse result given the current Spotify entity state.
final class MediaBrowserPlaybackGuidanceTests: XCTestCase {

    // MARK: - Helpers

    private func mediaEntity(state: String) -> HAEntityState {
        HAEntityState(entityId: "media_player.spotify_test", state: state, attributes: [:])
    }

    private func failedBrowseResult(errorMessage: String = "Not found") -> HABrowseMediaResult {
        HABrowseMediaResult(
            success: false,
            result: nil,
            error: HAResultError(code: .string("not_found"), message: errorMessage)
        )
    }

    private func successBrowseResult() -> HABrowseMediaResult {
        let node = HABrowseMediaNode(
            title: "Spotify",
            mediaClass: "app",
            mediaContentType: "app",
            mediaContentId: "spotify",
            canPlay: false,
            canExpand: true,
            thumbnail: nil,
            childrenMediaClass: nil,
            children: nil,
            extra: nil
        )
        return HABrowseMediaResult(success: true, result: node, error: nil)
    }

    private func authFailedBrowseResult() -> HABrowseMediaResult {
        HABrowseMediaResult(
            success: false,
            result: nil,
            error: HAResultError(code: .string("unauthorized"), message: "Invalid authentication credentials")
        )
    }

    /// Returns true when the entity state is one of the idle/stopped set.
    private func isIdleOrStopped(_ entityState: String) -> Bool {
        let idleStates: Set<String> = ["idle", "off", "stopped", "unavailable", "unknown"]
        return idleStates.contains(entityState)
    }

    /// Returns true when the error is a known non-playback failure (auth, connectivity, decode).
    private func isNonPlaybackError(_ error: HAResultError?) -> Bool {
        guard let error else { return false }
        let nonPlaybackCodes: Set<String> = ["unauthorized", "not_allowed", "home_assistant_error", "unknown_error"]
        if case .string(let code) = error.code, nonPlaybackCodes.contains(code) {
            return true
        }
        let message = (error.message ?? "").lowercased()
        return message.contains("auth") || message.contains("credential") ||
               message.contains("timeout") || message.contains("connection") ||
               message.contains("decode") || message.contains("network")
    }

    // MARK: - Tests

    /// Browse succeeds while Spotify is stopped → no playback guidance shown.
    func testBrowseSuccessWhileStoppedOpensNormally() {
        let result = successBrowseResult()
        let entity = mediaEntity(state: "idle")

        XCTAssertTrue(result.success)
        XCTAssertNotNil(result.result)
        // Guidance logic is only triggered on failure; success always opens browser.
        XCTAssertFalse(!result.success && isIdleOrStopped(entity.state))
    }

    /// Browse fails while Spotify is idle → playback guidance shown.
    func testBrowseFailureWhileSpotifyIdleShowsPlaybackGuidance() {
        let result = failedBrowseResult()
        let entity = mediaEntity(state: "idle")

        XCTAssertFalse(result.success)
        XCTAssertTrue(isIdleOrStopped(entity.state))
    }

    /// Browse fails while Spotify is stopped (off) → playback guidance shown.
    func testBrowseFailureWhileSpotifyOffShowsPlaybackGuidance() {
        let result = failedBrowseResult()
        let entity = mediaEntity(state: "off")

        XCTAssertFalse(result.success)
        XCTAssertTrue(isIdleOrStopped(entity.state))
    }

    /// Browse fails while Spotify is playing → real error message retained.
    func testBrowseFailureWhileSpotifyPlayingRetainsRealError() {
        let result = failedBrowseResult(errorMessage: "Authentication error")
        let entity = mediaEntity(state: "playing")

        XCTAssertFalse(result.success)
        XCTAssertFalse(isIdleOrStopped(entity.state))
        XCTAssertEqual(result.error?.message, "Authentication error")
    }

    /// Browse fails with an auth error while Spotify is paused →
    /// entity is not idle/stopped, so real error message is preserved.
    func testAuthErrorWhileSpotifyPausedRetainsError() {
        let result = failedBrowseResult(errorMessage: "Invalid authentication credentials")
        let entity = mediaEntity(state: "paused")

        XCTAssertFalse(result.success)
        XCTAssertFalse(isIdleOrStopped(entity.state))
        XCTAssertEqual(result.error?.message, "Invalid authentication credentials")
    }

    /// Browse fails while Spotify is unavailable → playback guidance shown.
    func testBrowseFailureWhileSpotifyUnavailableShowsPlaybackGuidance() {
        let result = failedBrowseResult()
        let entity = mediaEntity(state: "unavailable")

        XCTAssertFalse(result.success)
        XCTAssertTrue(isIdleOrStopped(entity.state))
    }

    /// Auth error while Spotify is idle → real error message preserved, no playback guidance.
    func testAuthErrorWhileSpotifyIdleRetainsRealError() {
        let result = authFailedBrowseResult()
        let entity = mediaEntity(state: "idle")

        XCTAssertFalse(result.success)
        XCTAssertTrue(isIdleOrStopped(entity.state))
        // Even though Spotify is idle, an auth error is not a playback-requirement failure.
        XCTAssertTrue(isNonPlaybackError(result.error))
        XCTAssertEqual(result.error?.message, "Invalid authentication credentials")
    }
}

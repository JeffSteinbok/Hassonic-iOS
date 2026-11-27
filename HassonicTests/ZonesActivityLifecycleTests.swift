import XCTest
@testable import Hassonic

/// When the speaker Live Activity stays and when it goes.
final class ZonesActivityLifecycleTests: XCTestCase {

    private func entity(_ state: String, title: String? = "Song", lastChanged: String? = nil) -> HAEntityState {
        var attributes: [String: JSONValue] = [:]
        if let title { attributes["media_title"] = .string(title) }
        return HAEntityState(entityId: "media_player.spotify", state: state, attributes: attributes, lastChanged: lastChanged)
    }

    private typealias Lifecycle = ZonesActivityLifecycle
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Playback

    func testPlayingAndBufferingArePlaying() {
        XCTAssertEqual(Lifecycle.playback(of: entity("playing")), .playing)
        XCTAssertEqual(Lifecycle.playback(of: entity("buffering")), .playing)
    }

    func testPausedOrIdleWithATrackIsPaused() {
        XCTAssertEqual(Lifecycle.playback(of: entity("paused")), .paused)
        XCTAssertEqual(Lifecycle.playback(of: entity("idle")), .paused)
        XCTAssertEqual(Lifecycle.playback(of: entity("on")), .paused)
    }

    func testNothingLoadedIsStopped() {
        XCTAssertEqual(Lifecycle.playback(of: entity("paused", title: nil)), .stopped)
        XCTAssertEqual(Lifecycle.playback(of: entity("idle", title: nil)), .stopped)
    }

    /// Even with a title left over in the attributes.
    func testOffUnavailableAndStandbyAreStopped() {
        for state in ["off", "unavailable", "unknown", "standby", "stopped"] {
            XCTAssertEqual(Lifecycle.playback(of: entity(state)), .stopped, state)
        }
    }

    func testMissingEntityIsStopped() {
        XCTAssertEqual(Lifecycle.playback(of: nil), .stopped)
    }

    // MARK: - Decision

    func testPlayingKeepsIt() {
        XCTAssertEqual(Lifecycle.decision(.playing, notPlayingSince: now.addingTimeInterval(-3600), now: now), .keep)
    }

    func testStoppedEndsItAtOnce() {
        XCTAssertEqual(Lifecycle.decision(.stopped, notPlayingSince: now, now: now), .end)
    }

    /// A pause from the activity's own key mustn't take it away.
    func testABriefPauseKeepsItUntilTheGracePeriodRunsOut() {
        let pausedAt = now.addingTimeInterval(-10)
        XCTAssertEqual(
            Lifecycle.decision(.paused, notPlayingSince: pausedAt, now: now),
            .keepUntil(pausedAt.addingTimeInterval(Lifecycle.pauseGrace))
        )
    }

    func testALongPauseEndsIt() {
        let pausedAt = now.addingTimeInterval(-Lifecycle.pauseGrace)
        XCTAssertEqual(Lifecycle.decision(.paused, notPlayingSince: pausedAt, now: now), .end)
    }

    func testTheGracePeriodIsShort() {
        XCTAssertGreaterThanOrEqual(Lifecycle.pauseGrace, 30)
        XCTAssertLessThanOrEqual(Lifecycle.pauseGrace, 10 * 60)
    }

    // MARK: - When it stopped

    func testNotPlayingSinceUsesHomeAssistantsLastChanged() {
        // `now` is 2027-01-15T08:00:00Z.
        let since = Lifecycle.notPlayingSince(entity("paused", lastChanged: "2027-01-15T07:55:00.123456+00:00"), fallback: now)
        XCTAssertEqual(since.timeIntervalSince(now), -300, accuracy: 1)
    }

    func testNotPlayingSinceFallsBackWithoutATimestamp() {
        XCTAssertEqual(Lifecycle.notPlayingSince(entity("paused"), fallback: now), now)
        XCTAssertEqual(Lifecycle.notPlayingSince(entity("paused", lastChanged: "garbage"), fallback: now), now)
    }

    /// Home Assistant's clock running ahead mustn't stretch the grace period.
    func testNotPlayingSinceNeverLaterThanTheFallback() {
        let future = Lifecycle.notPlayingSince(entity("paused", lastChanged: "2099-01-01T00:00:00+00:00"), fallback: now)
        XCTAssertEqual(future, now)
    }
}

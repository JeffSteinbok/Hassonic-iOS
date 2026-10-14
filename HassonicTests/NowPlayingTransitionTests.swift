import XCTest
@testable import Hassonic

@MainActor
final class NowPlayingTransitionTests: XCTestCase {

    // MARK: - Helpers

    private func entity(
        state: String = "playing",
        title: String? = nil,
        artist: String? = nil,
        contentId: String? = nil,
        picture: String? = nil,
        duration: Double? = nil,
        position: Double? = nil,
        positionUpdatedAt: Date? = nil
    ) -> HAEntityState {
        var attrs: [String: Any] = [:]
        if let title { attrs["media_title"] = title }
        if let artist { attrs["media_artist"] = artist }
        if let contentId { attrs["media_content_id"] = contentId }
        if let picture { attrs["entity_picture"] = picture }
        if let duration { attrs["media_duration"] = duration }
        if let position { attrs["media_position"] = position }
        if let positionUpdatedAt {
            // As Home Assistant writes it: microseconds and a +00:00 offset.
            let stamp = ISO8601DateFormatter().string(from: positionUpdatedAt)
            attrs["media_position_updated_at"] = stamp.replacingOccurrences(of: "Z", with: ".000000+00:00")
        }

        let json: [String: Any] = ["entity_id": "media_player.spotify", "state": state, "attributes": attrs]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(HAEntityState.self, from: data)
    }

    // MARK: - trackIdentity

    func testTrackIdentityIsEmptyForNilEntity() {
        XCTAssertEqual(trackIdentity(for: nil), "")
    }

    func testTrackIdentityDiffersForDifferentTitles() {
        let a = entity(state: "playing", title: "Song A")
        let b = entity(state: "playing", title: "Song B")
        XCTAssertNotEqual(trackIdentity(for: a), trackIdentity(for: b))
    }

    func testTrackIdentityUnchangedByStateChange() {
        let playing = entity(state: "playing", title: "Song", contentId: "spotify:track:123")
        let paused  = entity(state: "paused",  title: "Song", contentId: "spotify:track:123")
        XCTAssertEqual(trackIdentity(for: playing), trackIdentity(for: paused))
    }

    func testTrackIdentityUnchangedByPositionChange() {
        let a = entity(state: "playing", title: "Song", contentId: "spotify:track:123", position: 10)
        let b = entity(state: "playing", title: "Song", contentId: "spotify:track:123", position: 60)
        XCTAssertEqual(trackIdentity(for: a), trackIdentity(for: b))
    }

    func testTrackIdentityChangesWhenArtworkURLChanges() {
        let a = entity(state: "playing", title: "Song", picture: "/api/art/track1.jpg")
        let b = entity(state: "playing", title: "Song", picture: "/api/art/track2.jpg")
        XCTAssertNotEqual(trackIdentity(for: a), trackIdentity(for: b))
    }

    // MARK: - NowPlayingTransitionManager — normal track change

    func testManagerCommitsEmptyPresentationForNilEntity() async {
        let manager = NowPlayingTransitionManager()
        manager.artworkTimeoutSeconds = 0
        manager.update(entity: nil, baseURLString: "")
        // Allow task to settle
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(manager.committed.hasMedia)
        XCTAssertNil(manager.committed.title)
    }

    func testManagerCommitsPresentationWithNoArtworkImmediately() async {
        let manager = NowPlayingTransitionManager()
        manager.artworkTimeoutSeconds = 0.05
        let e = entity(state: "playing", title: "Track", artist: "Artist")
        manager.update(entity: e, baseURLString: "")
        // Without artwork, there is no URL to fetch — the task should resolve quickly.
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(manager.committed.hasMedia)
        XCTAssertEqual(manager.committed.title, "Track")
        XCTAssertEqual(manager.committed.artist, "Artist")
        XCTAssertNil(manager.committed.artworkURL)
    }

    // MARK: - Pause/resume does not trigger media transition

    func testPauseDoesNotChangeCommittedPresentation() async {
        let manager = NowPlayingTransitionManager()
        manager.artworkTimeoutSeconds = 0.05
        let playing = entity(state: "playing", title: "Track", contentId: "id:1")
        manager.update(entity: playing, baseURLString: "")
        try? await Task.sleep(for: .milliseconds(200))

        let committedTitle = manager.committed.title

        let paused = entity(state: "paused", title: "Track", contentId: "id:1")
        manager.update(entity: paused, baseURLString: "")
        await Task.yield()
        // Title must remain unchanged (no new track loaded).
        XCTAssertEqual(manager.committed.title, committedTitle)
    }

    // MARK: - Rapid track skips settle on the latest

    func testRapidSkipsSettleOnLatestTrack() async {
        let manager = NowPlayingTransitionManager()
        manager.artworkTimeoutSeconds = 0.05

        manager.update(entity: entity(state: "playing", title: "Track 1", contentId: "id:1"), baseURLString: "")
        manager.update(entity: entity(state: "playing", title: "Track 2", contentId: "id:2"), baseURLString: "")
        manager.update(entity: entity(state: "playing", title: "Track 3", contentId: "id:3"), baseURLString: "")

        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(manager.committed.title, "Track 3")
    }

    // MARK: - Failed artwork fallback

    func testFailedArtworkFallsBackWithinTimeout() async {
        let manager = NowPlayingTransitionManager()
        // Use a very short timeout so the test doesn't take long.
        manager.artworkTimeoutSeconds = 0.1
        // Use a URL that will fail (localhost nothing listening).
        let e = entity(state: "playing", title: "Track", picture: "http://127.0.0.1:1/nonexistent.jpg")
        manager.update(entity: e, baseURLString: "http://127.0.0.1:1")
        // Wait longer than the timeout.
        try? await Task.sleep(for: .milliseconds(500))
        // Even with failed artwork, the presentation must be committed.
        XCTAssertTrue(manager.committed.hasMedia)
        XCTAssertEqual(manager.committed.title, "Track")
    }

    // MARK: - Reduce Motion: animation runs without crashing

    func testUpdateDoesNotCrashWithReduceMotion() async {
        // NowPlayingTransitionManager uses withAnimation which respects accessibility settings.
        // This smoke-tests that the code path executes without error under any motion setting.
        let manager = NowPlayingTransitionManager()
        manager.artworkTimeoutSeconds = 0.05
        manager.update(entity: entity(state: "playing", title: "T"), baseURLString: "")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(manager.committed.hasMedia)
    }

    // MARK: - Playback timeline lifecycle (regression for frozen elapsed time)

    /// After a track commits, `anchorUpdatedAt` must be non-nil so the `TimelineView`
    /// schedule can anchor to a stable date rather than re-anchoring to `Date()` on
    /// every body evaluation (which caused the elapsed time to freeze).
    func testCommittedPresentationHasAnchorUpdatedAt() async {
        let manager = NowPlayingTransitionManager()
        manager.artworkTimeoutSeconds = 0.05
        let anchor = Date(timeIntervalSinceNow: -15)
        let e = entity(state: "playing", title: "Track", contentId: "id:1",
                       duration: 300, position: 60, positionUpdatedAt: anchor)
        manager.update(entity: e, baseURLString: "")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(manager.committed.anchorUpdatedAt,
                        "anchorUpdatedAt must be committed so the timeline schedule has a stable anchor")
        XCTAssertEqual(manager.committed.anchorPosition, 60)
        XCTAssertEqual(manager.committed.duration, 300)
    }

    /// A same-track position re-anchor (HA sends a new `media_position_updated_at`)
    /// must update the committed presentation in-place without triggering a full
    /// artwork-load transition, so the elapsed time re-anchors smoothly.
    func testSameTrackPositionReanchorUpdatesCommittedInPlace() async {
        let manager = NowPlayingTransitionManager()
        manager.artworkTimeoutSeconds = 0.05
        let first = entity(state: "playing", title: "Track", contentId: "id:1",
                           duration: 300, position: 60,
                           positionUpdatedAt: Date(timeIntervalSinceNow: -10))
        manager.update(entity: first, baseURLString: "")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(manager.committed.anchorPosition, 60)

        // Simulate HA sending a fresh position without a track change.
        let newAnchor = Date()
        let second = entity(state: "playing", title: "Track", contentId: "id:1",
                            duration: 300, position: 85,
                            positionUpdatedAt: newAnchor)
        manager.update(entity: second, baseURLString: "")
        await Task.yield()
        XCTAssertEqual(manager.committed.anchorPosition, 85,
                       "same-track position update must re-anchor without a full transition")
        XCTAssertNotNil(manager.committed.anchorUpdatedAt)
    }

    func testPlaybackAnchorIdentityChangesForPositionUpdate() {
        let anchor = Date()
        let first = entity(state: "playing", title: "Track", contentId: "id:1",
                           duration: 300, position: 60, positionUpdatedAt: anchor)
        let second = entity(state: "playing", title: "Track", contentId: "id:1",
                            duration: 300, position: 61, positionUpdatedAt: anchor.addingTimeInterval(1))

        XCTAssertNotEqual(playbackAnchorIdentity(for: first), playbackAnchorIdentity(for: second))
        XCTAssertEqual(trackIdentity(for: first), trackIdentity(for: second))
    }

    /// Pause sets committed state to "paused" immediately (same-track path),
    /// so the progress view freezes the elapsed time right away.
    func testPauseSetsCommittedStateToPaused() async {
        let manager = NowPlayingTransitionManager()
        manager.artworkTimeoutSeconds = 0.05
        let playing = entity(state: "playing", title: "Track", contentId: "id:1",
                             duration: 300, position: 60,
                             positionUpdatedAt: Date(timeIntervalSinceNow: -5))
        manager.update(entity: playing, baseURLString: "")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(manager.committed.state, "playing")

        let paused = entity(state: "paused", title: "Track", contentId: "id:1",
                            duration: 300, position: 65,
                            positionUpdatedAt: Date())
        manager.update(entity: paused, baseURLString: "")
        await Task.yield()
        XCTAssertEqual(manager.committed.state, "paused",
                       "pause must update committed state immediately so elapsed time freezes")
    }

    /// Artwork loading, timeout, success, and failure must not alter anchorUpdatedAt
    /// or state on the committed presentation — the playback clock must keep running
    /// while artwork is being fetched or timed out.
    func testArtworkLoadDoesNotCorruptAnchorOrState() async {
        let manager = NowPlayingTransitionManager()
        // Short timeout so the test exercises the timeout path quickly.
        manager.artworkTimeoutSeconds = 0.1
        let anchor = Date(timeIntervalSinceNow: -20)
        // Use a URL that will not respond so both the real-load and timeout paths are exercised.
        let e = entity(state: "playing", title: "Track", contentId: "id:1",
                       picture: "http://127.0.0.1:1/art.jpg",
                       duration: 300, position: 80, positionUpdatedAt: anchor)
        manager.update(entity: e, baseURLString: "http://127.0.0.1:1")
        try? await Task.sleep(for: .milliseconds(500))

        XCTAssertTrue(manager.committed.hasMedia,
                      "presentation must be committed after artwork timeout")
        XCTAssertEqual(manager.committed.state, "playing",
                       "artwork timeout must not alter committed state")
        XCTAssertEqual(manager.committed.anchorUpdatedAt?.timeIntervalSinceReferenceDate ?? 0,
                       anchor.timeIntervalSinceReferenceDate, accuracy: 1.0,
                       "artwork timeout must not alter anchorUpdatedAt")
        XCTAssertEqual(manager.committed.anchorPosition, 80,
                       "artwork timeout must not alter anchorPosition")
    }

    /// A successful (or failed) artwork load for the same track must not reset
    /// anchorUpdatedAt when a subsequent same-track in-place update arrives.
    func testArtworkSuccessFollowedBySameTrackUpdatePreservesAnchor() async {
        let manager = NowPlayingTransitionManager()
        manager.artworkTimeoutSeconds = 0.05
        let anchor1 = Date(timeIntervalSinceNow: -30)
        let e1 = entity(state: "playing", title: "Track", contentId: "id:1",
                        duration: 300, position: 50, positionUpdatedAt: anchor1)
        manager.update(entity: e1, baseURLString: "")
        try? await Task.sleep(for: .milliseconds(200))

        // Simulate HA position update (same track, no artwork URL change).
        let anchor2 = Date(timeIntervalSinceNow: -5)
        let e2 = entity(state: "playing", title: "Track", contentId: "id:1",
                        duration: 300, position: 75, positionUpdatedAt: anchor2)
        manager.update(entity: e2, baseURLString: "")
        await Task.yield()

        XCTAssertEqual(manager.committed.anchorPosition, 75,
                       "in-place update after artwork commit must update anchorPosition")
        XCTAssertEqual(manager.committed.anchorUpdatedAt?.timeIntervalSinceReferenceDate ?? 0,
                       anchor2.timeIntervalSinceReferenceDate, accuracy: 1.0,
                       "in-place update after artwork commit must update anchorUpdatedAt")
        XCTAssertEqual(manager.committed.state, "playing",
                       "in-place update must not alter state")
    }

    /// Committed presentation must survive being re-observed by a new view instance
    /// (simulating a tab switch) without requiring a fresh HA entity push.
    func testCommittedPresentationSurvivesReObservation() async {
        let manager = NowPlayingTransitionManager()
        manager.artworkTimeoutSeconds = 0.05
        let anchor = Date(timeIntervalSinceNow: -10)
        let e = entity(state: "playing", title: "Track", contentId: "id:1",
                       duration: 240, position: 45, positionUpdatedAt: anchor)
        manager.update(entity: e, baseURLString: "")
        try? await Task.sleep(for: .milliseconds(200))

        // Capture the committed values.
        let snap = manager.committed

        // Simulate a new subscriber (view re-creation / tab return): read published state again.
        let reObserved = manager.committed
        XCTAssertEqual(reObserved.anchorPosition, snap.anchorPosition,
                       "re-observing committed must return the same anchorPosition without a new HA push")
        XCTAssertEqual(reObserved.anchorUpdatedAt, snap.anchorUpdatedAt,
                       "re-observing committed must return the same anchorUpdatedAt without a new HA push")
        XCTAssertEqual(reObserved.state, "playing",
                       "re-observing committed must return the same state without a new HA push")
    }

    // MARK: - Empty-to-playing and playing-to-empty placeholder transitions

    /// Empty state transitions to playing: committed becomes hasMedia = true and
    /// placeholder must be gone (hasMedia drives the placeholder's visibility).
    func testEmptyToPlayingTransitionSetsHasMedia() async {
        let manager = NowPlayingTransitionManager()
        manager.artworkTimeoutSeconds = 0.05
        // Start empty.
        manager.update(entity: nil, baseURLString: "")
        await Task.yield()
        XCTAssertFalse(manager.committed.hasMedia, "initial state must be empty")

        // Transition to playing (no artwork URL, so the task completes after one yield).
        let playing = entity(state: "playing", title: "Track A", contentId: "id:A")
        manager.update(entity: playing, baseURLString: "")
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(manager.committed.hasMedia, "committed must report hasMedia after transition from empty to playing")
        XCTAssertEqual(manager.committed.title, "Track A")
    }

    /// Playing state transitions back to idle/empty: committed becomes hasMedia = false
    /// so the placeholder is shown again and stale artwork is not retained.
    func testPlayingToEmptyTransitionClearsMedia() async {
        let manager = NowPlayingTransitionManager()
        manager.artworkTimeoutSeconds = 0.05
        let playing = entity(state: "playing", title: "Track B", contentId: "id:B")
        manager.update(entity: playing, baseURLString: "")
        // No artwork URL — task completes after one cooperative yield.
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(manager.committed.hasMedia, "must have media while playing")

        // Transition to idle (nothing playing).
        manager.update(entity: entity(state: "idle"), baseURLString: "")
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(manager.committed.hasMedia, "committed must report no media after playing-to-idle transition")
        XCTAssertNil(manager.committed.artworkURL, "stale artwork URL must be cleared on empty transition")
    }

    // MARK: - Unavailable-artwork / disconnected deterministic paths

    /// When the entity has `entity_picture` set but the player state is "unavailable",
    /// `nowPlayingHasMedia` returns false, so the committed presentation must be empty
    /// and no stale artwork URL is retained.
    func testUnavailableStateProducesEmptyPresentationWithNoArtwork() async {
        let manager = NowPlayingTransitionManager()
        manager.artworkTimeoutSeconds = 0.05
        let unavailable = entity(state: "unavailable", title: nil, picture: "/api/art/stale.jpg")
        manager.update(entity: unavailable, baseURLString: "http://ha.local")
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(manager.committed.hasMedia, "unavailable state must produce empty presentation")
        XCTAssertNil(manager.committed.artworkURL, "unavailable state must not retain artwork URL")
        XCTAssertNil(manager.committed.title, "unavailable state must not retain title")
    }

    /// When the entity transitions from playing to "unavailable" (disconnected),
    /// the committed presentation clears atomically — no stale metadata is displayed.
    func testPlayingToUnavailableClearsPresentation() async {
        let manager = NowPlayingTransitionManager()
        manager.artworkTimeoutSeconds = 0.05
        let playing = entity(state: "playing", title: "Track C", contentId: "id:C")
        manager.update(entity: playing, baseURLString: "")
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(manager.committed.hasMedia, "must have media while playing")

        let unavailable = entity(state: "unavailable", title: nil)
        manager.update(entity: unavailable, baseURLString: "")
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(manager.committed.hasMedia,
                       "committed must be empty after transition to unavailable (disconnected)")
        XCTAssertNil(manager.committed.title, "stale title must be cleared on unavailable transition")
        XCTAssertNil(manager.committed.artworkURL, "stale artwork URL must be cleared on unavailable transition")
    }

    /// A playing entity with a picture path that fails to load must still produce
    /// a committed presentation with hasMedia = true after the timeout, and state/title
    /// remain stable — no stale-artwork flash.
    func testUnavailableArtworkURLFallbackIsStable() async {
        let manager = NowPlayingTransitionManager()
        manager.artworkTimeoutSeconds = 0.1
        let e = entity(state: "playing", title: "Track D", contentId: "id:D",
                       picture: "http://127.0.0.1:1/art.jpg")
        manager.update(entity: e, baseURLString: "http://127.0.0.1:1")
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(manager.committed.hasMedia,
                      "presentation must be committed after artwork URL load fails/times out")
        XCTAssertEqual(manager.committed.title, "Track D",
                       "title must be stable after unavailable-artwork fallback")
        XCTAssertEqual(manager.committed.state, "playing",
                       "state must not be corrupted by artwork load failure")
    }

    /// Track change must reset anchor position to the new track's starting position
    /// rather than carrying over elapsed time from the previous track.
    func testTrackChangeResetsAnchorPosition() async {
        let manager = NowPlayingTransitionManager()
        manager.artworkTimeoutSeconds = 0.05
        let track1 = entity(state: "playing", title: "Track 1", contentId: "id:1",
                            duration: 200, position: 150,
                            positionUpdatedAt: Date(timeIntervalSinceNow: -10))
        manager.update(entity: track1, baseURLString: "")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(manager.committed.anchorPosition, 150)

        let track2 = entity(state: "playing", title: "Track 2", contentId: "id:2",
                            duration: 300, position: 0,
                            positionUpdatedAt: Date())
        manager.update(entity: track2, baseURLString: "")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(manager.committed.title, "Track 2",
                       "committed title must update after track change")
        XCTAssertEqual(manager.committed.anchorPosition, 0,
                       "track change must reset anchor position to 0, not carry over previous track time")
    }
}

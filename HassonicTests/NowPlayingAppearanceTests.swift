import XCTest
@testable import Hassonic

final class NowPlayingAppearanceTests: XCTestCase {

    // MARK: - Helpers

    private func entity(state: String, attributes: [String: JSONValue] = [:]) -> HAEntityState {
        // HAEntityState is Decodable-only; round-trip via JSON to construct test instances.
        var json: [String: Any] = ["entity_id": "media_player.spotify", "state": state, "attributes": [:]]
        var attrs: [String: Any] = [:]
        for (key, value) in attributes {
            switch value {
            case .string(let s): attrs[key] = s
            case .number(let n): attrs[key] = n
            case .bool(let b): attrs[key] = b
            default: break
            }
        }
        json["attributes"] = attrs
        let data = try! JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(HAEntityState.self, from: data)
    }

    // MARK: - No media

    func testNilEntityHasNoMedia() {
        XCTAssertFalse(nowPlayingHasMedia(nil))
    }

    func testIdleStateWithNoTitleHasNoMedia() {
        XCTAssertFalse(nowPlayingHasMedia(entity(state: "idle")))
    }

    func testStoppedStateWithNoTitleHasNoMedia() {
        XCTAssertFalse(nowPlayingHasMedia(entity(state: "stopped")))
    }

    func testOffStateWithNoTitleHasNoMedia() {
        XCTAssertFalse(nowPlayingHasMedia(entity(state: "off")))
    }

    func testUnavailableStateWithNoTitleHasNoMedia() {
        XCTAssertFalse(nowPlayingHasMedia(entity(state: "unavailable")))
    }

    // MARK: - Playing media

    func testPlayingStateWithTitleHasMedia() {
        let e = entity(state: "playing", attributes: ["media_title": .string("Song Title")])
        XCTAssertTrue(nowPlayingHasMedia(e))
    }

    // MARK: - Paused media

    func testPausedStateWithTitleHasMedia() {
        let e = entity(state: "paused", attributes: ["media_title": .string("Song Title")])
        XCTAssertTrue(nowPlayingHasMedia(e))
    }

    func testPausedStateWithNoTitleHasNoMedia() {
        XCTAssertFalse(nowPlayingHasMedia(entity(state: "paused")))
    }

    // MARK: - Appearance transitions

    func testTransitionFromPlayingToIdleRemovesMedia() {
        let playing = entity(state: "playing", attributes: ["media_title": .string("Song")])
        let idle = entity(state: "idle")
        XCTAssertTrue(nowPlayingHasMedia(playing))
        XCTAssertFalse(nowPlayingHasMedia(idle))
    }

    // MARK: - Scrim coverage: artwork fixture scenarios

    /// Very-light artwork: hasMedia must be true so contrast scrims are applied.
    func testVeryLightArtworkFixtureHasMedia() {
        let e = entity(
            state: "playing",
            attributes: [
                "media_title": .string("Snowy Mountain"),
                "media_artist": .string("Artist"),
                "entity_picture": .string("/api/media_player_proxy/light_fixture.jpg")
            ]
        )
        XCTAssertTrue(nowPlayingHasMedia(e))
    }

    /// Mixed-brightness artwork: hasMedia must be true so contrast scrims are applied.
    func testMixedArtworkFixtureHasMedia() {
        let e = entity(
            state: "playing",
            attributes: [
                "media_title": .string("Autumn Forest"),
                "media_artist": .string("Artist"),
                "entity_picture": .string("/api/media_player_proxy/mixed_fixture.jpg")
            ]
        )
        XCTAssertTrue(nowPlayingHasMedia(e))
    }

    /// Very-dark artwork: hasMedia must be true so contrast scrims are applied.
    func testVeryDarkArtworkFixtureHasMedia() {
        let e = entity(
            state: "playing",
            attributes: [
                "media_title": .string("Midnight Sky"),
                "media_artist": .string("Artist"),
                "entity_picture": .string("/api/media_player_proxy/dark_fixture.jpg")
            ]
        )
        XCTAssertTrue(nowPlayingHasMedia(e))
    }

    /// Missing artwork (entity_picture absent) with a playing track: hasMedia true,
    /// so the card still shows the dark fallback background with scrims.
    func testMissingArtworkWithPlayingTrackHasMedia() {
        let e = entity(
            state: "playing",
            attributes: ["media_title": .string("No Cover Track")]
        )
        XCTAssertTrue(nowPlayingHasMedia(e))
    }

    /// Nothing Playing state: hasMedia false, so semantic system appearance is retained.
    func testNothingPlayingStateHasNoMedia() {
        XCTAssertFalse(nowPlayingHasMedia(entity(state: "idle")))
        XCTAssertFalse(nowPlayingHasMedia(entity(state: "off")))
        XCTAssertFalse(nowPlayingHasMedia(nil))
    }
}

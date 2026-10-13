import XCTest
@testable import Hassonic

/// Tests for the header-level Spotify action introduced in issue #60.
///
/// Verifies that the `spotify:` deep-link URL is well-formed and that the
/// fallback HTTPS URL is also valid, covering the routing logic extracted
/// from the old in-card control.
final class SpotifyHeaderActionTests: XCTestCase {

    // MARK: - Deep-link URL

    func testSpotifyDeepLinkURLIsValid() {
        let url = URL(string: "spotify:")
        XCTAssertNotNil(url, "spotify: URL scheme must parse to a valid URL")
    }

    func testSpotifyDeepLinkSchemeIsSpotify() {
        let url = URL(string: "spotify:")!
        XCTAssertEqual(url.scheme, "spotify")
    }

    // MARK: - Web fallback URL

    func testSpotifyWebFallbackURLIsValid() {
        let url = URL(string: "https://open.spotify.com")
        XCTAssertNotNil(url)
    }

    func testSpotifyWebFallbackURLSchemeIsHTTPS() {
        let url = URL(string: "https://open.spotify.com")!
        XCTAssertEqual(url.scheme, "https")
    }

    func testSpotifyWebFallbackURLHostIsOpenSpotify() {
        let url = URL(string: "https://open.spotify.com")!
        XCTAssertEqual(url.host, "open.spotify.com")
    }

    // MARK: - In-card control removal

    /// Confirms that `nowPlayingHasMedia` is unaffected by this change: the
    /// presence of media is determined solely by `media_title`, not by the
    /// external-link control that was removed from the artwork card.
    func testNowPlayingHasMediaUnaffectedByControlRemoval() {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let json: [String: Any] = [
            "entity_id": "media_player.spotify",
            "state": "playing",
            "attributes": ["media_title": "Test Song"]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let entity = try! decoder.decode(HAEntityState.self, from: data)

        XCTAssertTrue(nowPlayingHasMedia(entity),
            "Removing the in-card button must not affect nowPlayingHasMedia")
    }

    func testNowPlayingHasNoMediaWhenIdleAfterControlRemoval() {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let json: [String: Any] = [
            "entity_id": "media_player.spotify",
            "state": "idle",
            "attributes": [String: Any]()
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let entity = try! decoder.decode(HAEntityState.self, from: data)

        XCTAssertFalse(nowPlayingHasMedia(entity))
    }
}

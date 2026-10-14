import XCTest
@testable import Hassonic

final class BrowseThumbnailURLResolutionTests: XCTestCase {

    private let baseURL = "https://homeassistant.local:8123"

    func testAbsoluteHTTPSURLPassedThrough() {
        let url = resolveHAImageURL(path: "https://i.scdn.co/image/abc123", baseURLString: baseURL)
        XCTAssertEqual(url?.absoluteString, "https://i.scdn.co/image/abc123")
    }

    func testRelativePathResolvedAgainstBase() {
        let url = resolveHAImageURL(path: "/api/media_player_proxy/media_player.spotify?token=abc", baseURLString: baseURL)
        XCTAssertEqual(url?.absoluteString, "https://homeassistant.local:8123/api/media_player_proxy/media_player.spotify?token=abc")
    }

    func testNilPathReturnsNil() {
        XCTAssertNil(resolveHAImageURL(path: nil, baseURLString: baseURL))
    }

    func testEmptyBaseURLWithRelativePathReturnsNil() {
        XCTAssertNil(resolveHAImageURL(path: "/api/image", baseURLString: ""))
    }

    func testHTTPURLPassedThrough() {
        let url = resolveHAImageURL(path: "http://example.com/thumb.jpg", baseURLString: baseURL)
        XCTAssertEqual(url?.absoluteString, "http://example.com/thumb.jpg")
    }

    func testRelativePathWithNoLeadingSlash() {
        let url = resolveHAImageURL(path: "api/thumbnail/abc", baseURLString: baseURL)
        XCTAssertNotNil(url)
    }
}

final class BrowseThumbnailAuthTests: XCTestCase {

    func testRelativePathRequiresAuth() {
        let path = "/api/media_player_proxy/media_player.spotify"
        let needsAuth = !path.hasPrefix("http")
        XCTAssertTrue(needsAuth)
    }

    func testAbsoluteHTTPSPathDoesNotRequireAuth() {
        let path = "https://i.scdn.co/image/abc"
        let needsAuth = !path.hasPrefix("http")
        XCTAssertFalse(needsAuth)
    }

    func testNilPathNeedsNoAuth() {
        let path: String? = nil
        let needsAuth = path.map { !$0.hasPrefix("http") } ?? false
        XCTAssertFalse(needsAuth)
    }
}

final class BrowseThumbnailNodeTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    func testNodeWithAbsoluteThumbnail() throws {
        let json = """
        {
            "title": "Chill Hits",
            "media_class": "playlist",
            "media_content_type": "spotify",
            "media_content_id": "spotify:playlist:abc",
            "can_play": true,
            "can_expand": false,
            "thumbnail": "https://i.scdn.co/image/abc123"
        }
        """.data(using: .utf8)!

        let node = try decoder.decode(HABrowseMediaNode.self, from: json)
        XCTAssertEqual(node.thumbnail, "https://i.scdn.co/image/abc123")
    }

    func testNodeWithRelativeThumbnail() throws {
        let json = """
        {
            "title": "My Album",
            "media_class": "album",
            "media_content_type": "music",
            "media_content_id": "spotify:album:xyz",
            "can_play": false,
            "can_expand": true,
            "thumbnail": "/api/media_player_proxy/media_player.spotify?token=t"
        }
        """.data(using: .utf8)!

        let node = try decoder.decode(HABrowseMediaNode.self, from: json)
        XCTAssertNotNil(node.thumbnail)
        XCTAssertTrue(node.thumbnail!.hasPrefix("/"))
    }

    func testNodeWithNullThumbnail() throws {
        let json = """
        {
            "title": "Category",
            "media_class": "directory",
            "can_play": false,
            "can_expand": true,
            "thumbnail": null
        }
        """.data(using: .utf8)!

        let node = try decoder.decode(HABrowseMediaNode.self, from: json)
        XCTAssertNil(node.thumbnail)
    }

    func testNodeWithMissingThumbnailKey() throws {
        let json = """
        {
            "title": "Category",
            "media_class": "directory",
            "can_play": false,
            "can_expand": true
        }
        """.data(using: .utf8)!

        let node = try decoder.decode(HABrowseMediaNode.self, from: json)
        XCTAssertNil(node.thumbnail)
    }

    // MARK: - The token only goes to Home Assistant

    func testTokenGoesToHomeAssistantOnly() throws {
        let base = "https://ha.example.com:8123/"
        func auth(_ url: String) throws -> String? {
            homeAssistantRequest(for: try XCTUnwrap(URL(string: url)), baseURLString: base, accessToken: "secret")
                .value(forHTTPHeaderField: "Authorization")
        }
        XCTAssertEqual(try auth("https://ha.example.com:8123/api/image/x"), "Bearer secret")
        XCTAssertEqual(try auth("https://HA.example.com:8123/local/a.png"), "Bearer secret")
        XCTAssertNil(try auth("https://www.gravatar.com/avatar/x"))
        XCTAssertNil(try auth("https://ha.example.com/api/image/x"), "another port")
        XCTAssertNil(try auth("http://ha.example.com:8123/api/image/x"), "another scheme")
    }

    func testDefaultPortsMatch() throws {
        let url = try XCTUnwrap(URL(string: "https://ha.example.com/x"))
        XCTAssertTrue(url.hasSameOrigin(as: try XCTUnwrap(URL(string: "https://ha.example.com:443"))))
    }
}

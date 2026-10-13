import XCTest
@testable import Hassonic

final class BrowseMediaDecodingTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    func testExpandableCategoryDecodesCorrectly() throws {
        let json = """
        {
            "title": "Playlists",
            "media_class": "playlist",
            "media_content_type": "spotify",
            "media_content_id": "spotify://library/playlists",
            "can_play": false,
            "can_expand": true,
            "thumbnail": null,
            "children_media_class": "playlist",
            "children": null,
            "extra": null
        }
        """.data(using: .utf8)!

        let node = try decoder.decode(HABrowseMediaNode.self, from: json)

        XCTAssertEqual(node.title, "Playlists")
        XCTAssertEqual(node.mediaClass, "playlist")
        XCTAssertEqual(node.mediaContentType, "spotify")
        XCTAssertEqual(node.mediaContentId, "spotify://library/playlists")
        XCTAssertEqual(node.canExpand, true)
        XCTAssertEqual(node.canPlay, false)
        XCTAssertTrue(node.canBrowseChildren)
        XCTAssertFalse(node.isPlayable)
    }

    func testPlayableLeafDecodesCorrectly() throws {
        let json = """
        {
            "title": "Bohemian Rhapsody",
            "media_class": "track",
            "media_content_type": "music",
            "media_content_id": "spotify:track:4u7EnebtmKWzUH433cf5Qv",
            "can_play": true,
            "can_expand": false,
            "thumbnail": "https://example.com/thumb.jpg",
            "children_media_class": null,
            "children": null,
            "extra": null
        }
        """.data(using: .utf8)!

        let node = try decoder.decode(HABrowseMediaNode.self, from: json)

        XCTAssertEqual(node.title, "Bohemian Rhapsody")
        XCTAssertEqual(node.mediaContentType, "music")
        XCTAssertEqual(node.mediaContentId, "spotify:track:4u7EnebtmKWzUH433cf5Qv")
        XCTAssertEqual(node.canPlay, true)
        XCTAssertEqual(node.canExpand, false)
        XCTAssertTrue(node.isPlayable)
        XCTAssertFalse(node.canBrowseChildren)
    }

    func testMissingCanExpandAndCanPlayDefaultsToDisabled() throws {
        let json = """
        {
            "title": "Unknown Node",
            "media_class": null,
            "media_content_type": null,
            "media_content_id": null
        }
        """.data(using: .utf8)!

        let node = try decoder.decode(HABrowseMediaNode.self, from: json)

        XCTAssertNil(node.canExpand)
        XCTAssertNil(node.canPlay)
        XCTAssertFalse(node.canBrowseChildren)
        XCTAssertFalse(node.isPlayable)
    }

    func testResultEnvelopeWithExpandableRoot() throws {
        let json = """
        {
            "id": 7,
            "type": "result",
            "success": true,
            "result": {
                "title": "Spotify",
                "media_class": "app",
                "media_content_type": "app",
                "media_content_id": "spotify",
                "can_play": false,
                "can_expand": true,
                "thumbnail": null,
                "children_media_class": "directory",
                "children": [
                    {
                        "title": "Playlists",
                        "media_class": "directory",
                        "media_content_type": "spotify",
                        "media_content_id": "spotify://library/playlists",
                        "can_play": false,
                        "can_expand": true
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        let result = try decoder.decode(HABrowseMediaResult.self, from: json)

        XCTAssertTrue(result.success)
        let root = try XCTUnwrap(result.result)
        XCTAssertTrue(root.canBrowseChildren)
        let child = try XCTUnwrap(root.children?.first)
        XCTAssertEqual(child.title, "Playlists")
        XCTAssertTrue(child.canBrowseChildren)
        XCTAssertEqual(child.mediaContentId, "spotify://library/playlists")
    }
}

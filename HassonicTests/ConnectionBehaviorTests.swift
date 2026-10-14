import XCTest
@testable import Hassonic

@MainActor
final class ConnectionBehaviorTests: XCTestCase {

    // MARK: - Authentication flow states

    func testFirstRunShowsWelcome() {
        XCTAssertEqual(
            ConnectionLandingState.initial(savedURL: nil, savedToken: nil),
            .welcome
        )
    }

    func testIncompleteSavedConnectionShowsWelcome() {
        XCTAssertEqual(
            ConnectionLandingState.initial(
                savedURL: "https://example.ui.nabu.casa",
                savedToken: nil
            ),
            .welcome
        )
    }

    func testSavedConnectionBypassesWelcome() {
        XCTAssertEqual(
            ConnectionLandingState.initial(
                savedURL: "https://example.ui.nabu.casa",
                savedToken: "token"
            ),
            .connection
        )
    }

    func testAuthInvalidJSONMessage() throws {
        let data = try loadFixture(named: "ha_auth_invalid")
        let envelope = try JSONDecoder().decode(HAEnvelope.self, from: data)
        XCTAssertEqual(envelope.type, "auth_invalid")
    }

    func testAuthOkJSONMessage() throws {
        let data = try loadFixture(named: "ha_auth_ok")
        let envelope = try JSONDecoder().decode(HAEnvelope.self, from: data)
        XCTAssertEqual(envelope.type, "auth_ok")
    }

    // MARK: - Reconnection / disconnect

    func testForegroundReconnectDoesNothingAfterManualDisconnect() throws {
        let client = HAWebSocketClient()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:1"))
        client.connect(baseURL: url, accessToken: "token")
        client.disconnect()

        client.reconnectAfterForeground()

        XCTAssertEqual(client.connectionState, .disconnected)
    }

    /// Signing out forgets the token too, so nothing can reconnect with it.
    func testDisconnectForgetsTheServerAndToken() throws {
        let client = HAWebSocketClient()
        client.connect(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1")), accessToken: "token")
        client.disconnect()

        XCTAssertNil(client.accessToken)
        XCTAssertEqual(client.baseURLString, "")
        XCTAssertFalse(client.willRetry)
    }

    /// Browsing with no connection answers at once instead of waiting forever.
    func testBrowseWithoutAConnectionFailsAtOnce() async {
        let result = await HAWebSocketClient().browseMedia(entityId: "media_player.x")
        XCTAssertFalse(result.success)
        XCTAssertTrue(MediaBrowseFailure.isUnrelatedToPlayback(result.error))
    }

    // MARK: - Helper

    private func loadFixture(named name: String) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            XCTFail("Fixture \(name).json not found in test bundle — check target resource membership")
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }
}

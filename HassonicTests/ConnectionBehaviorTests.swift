import XCTest
import Combine
@testable import Hassonic

@MainActor
final class ConnectionBehaviorTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: - Authentication flow states

    func testInitialStateIsDisconnected() {
        let client = MockHAClient()
        XCTAssertEqual(client.connectionState, .disconnected)
    }

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

    func testConnectTransitionsToConnecting() throws {
        let client = MockHAClient()
        let url = try XCTUnwrap(URL(string: "http://homeassistant.local:8123"))
        client.connect(baseURL: url, accessToken: "token")
        XCTAssertEqual(client.connectionState, .connecting)
    }

    func testSuccessfulAuthTransitionsToConnected() throws {
        let client = MockHAClient()
        let url = try XCTUnwrap(URL(string: "http://homeassistant.local:8123"))
        client.connect(baseURL: url, accessToken: "token")
        client.simulateConnected()
        XCTAssertEqual(client.connectionState, .connected)
    }

    func testAuthFailureSetsFailedState() {
        let client = MockHAClient()
        client.simulateAuthError()
        if case .failed(let msg) = client.connectionState {
            XCTAssertFalse(msg.isEmpty)
            XCTAssertTrue(msg.localizedCaseInsensitiveContains("auth") || msg.localizedCaseInsensitiveContains("token"))
        } else {
            XCTFail("Expected .failed state after auth error")
        }
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

    func testDisconnectClearsStateAndEntities() {
        let client = MockHAClient()
        client.simulateConnected(entities: MockHAClient.Fixtures.mediaPlayerEntities)
        XCTAssertEqual(client.connectionState, .connected)
        client.disconnect()
        XCTAssertEqual(client.connectionState, .disconnected)
        XCTAssertTrue(client.entities.isEmpty)
    }

    func testReconnectAfterDisconnect() throws {
        let client = MockHAClient()
        let url = try XCTUnwrap(URL(string: "http://homeassistant.local:8123"))
        client.connect(baseURL: url, accessToken: "token1")
        client.simulateConnected()
        client.disconnect()
        client.connect(baseURL: url, accessToken: "token2")
        XCTAssertEqual(client.connectionState, .connecting)
        XCTAssertEqual(client.connectCalls.count, 2)
    }

    func testForegroundReconnectDoesNothingAfterManualDisconnect() throws {
        let client = HAWebSocketClient()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:1"))
        client.connect(baseURL: url, accessToken: "token")
        client.disconnect()

        client.reconnectAfterForeground()

        XCTAssertEqual(client.connectionState, .disconnected)
    }

    // MARK: - Error-state propagation

    func testNetworkFailureSetsFailedState() {
        let client = MockHAClient()
        client.simulateFailure("Connection timed out")
        if case .failed(let msg) = client.connectionState {
            XCTAssertEqual(msg, "Connection timed out")
        } else {
            XCTFail("Expected .failed state")
        }
    }

    func testConnectionStatePublisherEmitsChanges() throws {
        let client = MockHAClient()
        var observed: [HAConnectionState] = []
        client.$connectionState
            .sink { observed.append($0) }
            .store(in: &cancellables)

        let url = try XCTUnwrap(URL(string: "http://homeassistant.local:8123"))
        client.connect(baseURL: url, accessToken: "token")
        client.simulateConnected()
        client.disconnect()

        XCTAssertEqual(observed, [.disconnected, .connecting, .connected, .disconnected])
    }

    // MARK: - Connection screen — entities loaded internally, not displayed

    /// Verifies that connecting populates entities internally even though
    /// the Connection screen no longer renders the entity list.
    func testEntitiesLoadedInternallyAfterConnect() {
        let client = MockHAClient()
        client.simulateConnected(entities: MockHAClient.Fixtures.mediaPlayerEntities)
        XCTAssertEqual(client.connectionState, .connected)
        XCTAssertFalse(client.entities.isEmpty, "Entities must remain available internally for Music/Home/Security features")
    }

    // MARK: - Observable state updates from mocked HA responses

    func testSimulateConnectedPopulatesEntities() {
        let client = MockHAClient()
        client.simulateConnected(entities: MockHAClient.Fixtures.mediaPlayerEntities)
        XCTAssertEqual(client.entities.count, 2)
        XCTAssertNotNil(client.entity("media_player.living_room"))
        XCTAssertNotNil(client.entity("media_player.bedroom"))
    }

    func testEntitiesPublisherEmitsOnConnect() {
        let client = MockHAClient()
        var entityCounts: [Int] = []
        client.$entities
            .map(\.count)
            .sink { entityCounts.append($0) }
            .store(in: &cancellables)

        client.simulateConnected(entities: MockHAClient.Fixtures.mediaPlayerEntities)
        client.disconnect()

        XCTAssertEqual(entityCounts, [0, 2, 0])
    }

    func testEntityStateReflectsAttributesAfterConnect() {
        let client = MockHAClient()
        client.simulateConnected(entities: [MockHAClient.Fixtures.mediaPlayerPlaying])
        let entity = client.entity("media_player.living_room")
        XCTAssertEqual(entity?.state, "playing")
        XCTAssertEqual(entity?.friendlyName, "Living Room")
        if case .number(let vol)? = entity?.attributes["volume_level"] {
            XCTAssertEqual(vol, 0.4, accuracy: 0.001)
        } else {
            XCTFail("volume_level should be a number attribute")
        }
    }

    func testAlarmEntityStateReflectsDisarmed() {
        let client = MockHAClient()
        client.simulateConnected(entities: [MockHAClient.Fixtures.alarmDisarmed])
        let entity = client.entity("alarm_control_panel.home")
        XCTAssertEqual(entity?.state, "disarmed")
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

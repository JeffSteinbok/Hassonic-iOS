import XCTest
@testable import Hassonic

@MainActor
final class MockHAClientTests: XCTestCase {

    func testInitialStateIsDisconnected() {
        let mock = MockHAClient()
        XCTAssertEqual(mock.connectionState, .disconnected)
        XCTAssertTrue(mock.entities.isEmpty)
    }

    func testSimulateConnectedPopulatesEntities() {
        let mock = MockHAClient()
        mock.simulateConnected(entities: MockHAClient.Fixtures.mediaPlayerEntities)
        XCTAssertEqual(mock.connectionState, .connected)
        XCTAssertEqual(mock.entities.count, 2)
    }

    func testEntityLookupReturnsCorrectEntity() {
        let mock = MockHAClient()
        mock.simulateConnected(entities: MockHAClient.Fixtures.mediaPlayerEntities)
        let entity = mock.entity("media_player.living_room")
        XCTAssertNotNil(entity)
        XCTAssertEqual(entity?.state, "playing")
    }

    func testSimulateAuthErrorSetsFailedState() {
        let mock = MockHAClient()
        mock.simulateAuthError()
        if case .failed(let msg) = mock.connectionState {
            XCTAssertTrue(msg.contains("Authentication failed"))
        } else {
            XCTFail("Expected .failed connection state")
        }
    }

    func testSimulateFailureSetsFailedState() {
        let mock = MockHAClient()
        mock.simulateFailure("Network unreachable")
        if case .failed(let msg) = mock.connectionState {
            XCTAssertEqual(msg, "Network unreachable")
        } else {
            XCTFail("Expected .failed connection state")
        }
    }

    func testConnectRecordsCallAndSetsBaseURL() throws {
        let mock = MockHAClient()
        let url = try XCTUnwrap(URL(string: "http://homeassistant.local:8123"))
        mock.connect(baseURL: url, accessToken: "test-token")
        XCTAssertEqual(mock.connectCalls.count, 1)
        XCTAssertEqual(mock.connectCalls[0].accessToken, "test-token")
        XCTAssertEqual(mock.baseURLString, "http://homeassistant.local:8123")
        XCTAssertEqual(mock.connectionState, .connecting)
    }

    func testDisconnectRecordsCallAndClearsEntities() {
        let mock = MockHAClient()
        mock.simulateConnected(entities: MockHAClient.Fixtures.mediaPlayerEntities)
        mock.disconnect()
        XCTAssertTrue(mock.calledDisconnect)
        XCTAssertEqual(mock.connectionState, .disconnected)
        XCTAssertTrue(mock.entities.isEmpty)
    }

    func testVolumeSetRecordsCall() {
        let mock = MockHAClient()
        mock.setVolume("media_player.living_room", level: 0.5)
        XCTAssertEqual(mock.volumeSetCalls.count, 1)
        XCTAssertEqual(mock.volumeSetCalls[0].entityId, "media_player.living_room")
        XCTAssertEqual(mock.volumeSetCalls[0].level, 0.5)
    }

    func testAlarmFixtureHasExpectedState() {
        let entity = MockHAClient.Fixtures.alarmDisarmed
        XCTAssertEqual(entity.entityId, "alarm_control_panel.home")
        XCTAssertEqual(entity.state, "disarmed")
    }
}

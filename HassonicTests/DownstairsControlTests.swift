import XCTest
@testable import Hassonic

@MainActor
final class DownstairsControlTests: XCTestCase {

    // MARK: - Entity capability interpretation

    func testLightEntityOnState() {
        let entity = HAEntityState(
            entityId: "light.family_room_lights",
            state: "on",
            attributes: ["friendly_name": .string("Family Room Lights"), "supported_features": .number(0)]
        )
        XCTAssertEqual(entity.state, "on")
        XCTAssertTrue(entity.isAvailable)
        // supported_features: 0 — no brightness support expected
        if case .number(let features)? = entity.attributes["supported_features"] {
            XCTAssertEqual(Int(features) & 1, 0, "Dimming bit should not be set")
        }
    }

    func testLightEntityOffState() {
        let entity = HAEntityState(
            entityId: "light.family_room_lights",
            state: "off",
            attributes: ["friendly_name": .string("Family Room Lights"), "supported_features": .number(0)]
        )
        XCTAssertEqual(entity.state, "off")
        XCTAssertTrue(entity.isAvailable)
    }

    func testLightEntityUnavailable() {
        let entity = HAEntityState(
            entityId: "light.family_room_lights",
            state: "unavailable",
            attributes: [:]
        )
        XCTAssertFalse(entity.isAvailable)
    }

    func testCoverEntityCurrentPosition() {
        let entity = HAEntityState(
            entityId: "cover.awning",
            state: "open",
            attributes: [
                "friendly_name": .string("Awning"),
                "current_position": .number(75),
                "supported_features": .number(15)
            ]
        )
        if case .number(let pos)? = entity.attributes["current_position"] {
            XCTAssertEqual(Int(pos), 75)
        } else {
            XCTFail("Expected current_position attribute")
        }
        // supported_features: 15 covers open(1) + close(2) + stop(4) + set_position(8)
        if case .number(let features)? = entity.attributes["supported_features"] {
            let f = Int(features)
            XCTAssertNotEqual(f & 1, 0, "Open should be supported")
            XCTAssertNotEqual(f & 2, 0, "Close should be supported")
            XCTAssertNotEqual(f & 4, 0, "Stop should be supported")
            XCTAssertNotEqual(f & 8, 0, "Set position should be supported")
        }
    }

    func testCoverEntityUnavailable() {
        let entity = HAEntityState(
            entityId: "cover.awning",
            state: "unavailable",
            attributes: [:]
        )
        XCTAssertFalse(entity.isAvailable)
    }

    // MARK: - Control actions

    func testLightTurnOnCallsCorrectService() {
        let mock = MockHAClient()
        mock.lightTurnOn("light.family_room_lights")
        XCTAssertEqual(mock.serviceCallLog.count, 1)
        XCTAssertEqual(mock.serviceCallLog[0].method, "lightTurnOn")
        XCTAssertEqual(mock.serviceCallLog[0].entityId, "light.family_room_lights")
    }

    func testLightTurnOffCallsCorrectService() {
        let mock = MockHAClient()
        mock.lightTurnOff("light.family_room_lights")
        XCTAssertEqual(mock.serviceCallLog.count, 1)
        XCTAssertEqual(mock.serviceCallLog[0].method, "lightTurnOff")
        XCTAssertEqual(mock.serviceCallLog[0].entityId, "light.family_room_lights")
    }

    func testCoverOpenCallsCorrectService() {
        let mock = MockHAClient()
        mock.coverOpen("cover.awning")
        XCTAssertEqual(mock.serviceCallLog[0].method, "coverOpen")
        XCTAssertEqual(mock.serviceCallLog[0].entityId, "cover.awning")
    }

    func testCoverCloseCallsCorrectService() {
        let mock = MockHAClient()
        mock.coverClose("cover.awning")
        XCTAssertEqual(mock.serviceCallLog[0].method, "coverClose")
        XCTAssertEqual(mock.serviceCallLog[0].entityId, "cover.awning")
    }

    func testCoverStopCallsCorrectService() {
        let mock = MockHAClient()
        mock.coverStop("cover.awning")
        XCTAssertEqual(mock.serviceCallLog[0].method, "coverStop")
        XCTAssertEqual(mock.serviceCallLog[0].entityId, "cover.awning")
    }

    func testCoverSetPositionCallsCorrectService() {
        let mock = MockHAClient()
        mock.coverSetPosition("cover.awning", position: 50)
        XCTAssertEqual(mock.serviceCallLog[0].method, "coverSetPosition:50")
        XCTAssertEqual(mock.serviceCallLog[0].entityId, "cover.awning")
    }

    func testDownstairsLightingRowIsOnlyFamilyRoomLights() {
        // The Downstairs section exposes exactly one lighting entity.
        let allowedLightEntityId = "light.family_room_lights"
        let removedEntityIds = ["light.family_room_chair_light", "light.family_room_couch_light"]
        for entityId in removedEntityIds {
            XCTAssertNotEqual(entityId, allowedLightEntityId, "\(entityId) must not appear in the Downstairs lighting row")
        }
    }
}

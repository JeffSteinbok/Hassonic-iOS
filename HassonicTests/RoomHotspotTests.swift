import XCTest
@testable import Hassonic

/// What a room hotspot does when tapped, and what an appliance or sensor
/// hotspot reads, on the picture and in its sheet.
final class RoomHotspotTests: XCTestCase {

    private func hotspot(_ entity: String) -> DashboardRoomCardConfiguration.Hotspot {
        DashboardRoomCardConfiguration.Hotspot(entity: entity, x: 0.5, y: 0.5)
    }

    private func oven(_ state: String, target: Double = 0, current: Double = 100) -> HAEntityState {
        HAEntityState(entityId: "water_heater.upper_oven", state: state, attributes: [
            "operation_list": .array([.string("off"), .string("Bake"), .string("Convection Bake")]),
            "temperature": .number(target),
            "current_temperature": .number(current),
        ])
    }

    private let fridge = HAEntityState(entityId: "water_heater.fridge", state: "Normal", attributes: [
        "operation_list": .array([.string("Normal"), .string("Turbo Cool")]),
        "temperature": .number(37),
        "current_temperature": .null,
        "door_status": .string("Closed"),
    ])

    // MARK: Tapping

    func testLightsFansSwitchesSpeakersAndCoversToggle() {
        for entity in ["light.cans", "fan.ceiling", "switch.ice_maker", "input_boolean.guest", "media_player.kitchen", "cover.blinds"] {
            XCTAssertTrue(hotspot(entity).isToggleable, entity)
        }
    }

    /// These open their sheet on a tap: a stray tap on the picture must not
    /// start an oven.
    func testAppliancesAndSensorsOpenTheirSheetInsteadOfToggling() {
        for entity in ["water_heater.upper_oven", "binary_sensor.fridge_door", "sensor.oven_temperature", "select.oven_light", "climate.thermostat", "lock.front_door"] {
            XCTAssertFalse(hotspot(entity).isToggleable, entity)
        }
    }

    // MARK: Running

    func testAnOvenRunsWhenItIsNotOff() {
        XCTAssertFalse(oven("off").isApplianceRunning)
        XCTAssertTrue(oven("Bake").isApplianceRunning)
        XCTAssertFalse(oven("unavailable").isApplianceRunning)
    }

    func testAFridgeThatCannotBeOffNeverRuns() {
        XCTAssertFalse(fridge.isApplianceRunning)
    }

    // MARK: Readings

    func testAnOvenThatIsOffShowsNoTemperatures() {
        XCTAssertEqual(oven("off").readableState, "Off")
        XCTAssertEqual(oven("off").applianceDetails, [])
    }

    func testAHeatingOvenShowsItsSetAndCurrentTemperatures() {
        let heating = oven("Convection Bake", target: 350, current: 341.6)
        XCTAssertEqual(heating.readableState, "Convection Bake")
        XCTAssertEqual(heating.applianceDetails, ["Set to 350°", "Now 342°"])
    }

    func testAFridgeShowsItsSetpointAndDoor() {
        XCTAssertEqual(fridge.readableState, "Normal")
        XCTAssertEqual(fridge.applianceDetails, ["Set to 37°", "Door closed"])
    }

    // MARK: On the picture

    func testAnOvenShowsOffItsTemperatureOrItsClimbToTheSetpoint() {
        XCTAssertEqual(oven("off").hotspotReading, "Off")
        XCTAssertEqual(oven("Bake", target: 350, current: 212).hotspotReading, "212° → 350°")
        XCTAssertEqual(oven("Bake", target: 350, current: 348).hotspotReading, "348°")
        XCTAssertNil(oven("unavailable").hotspotReading)
    }

    func testAFridgeShowsItsSetpoint() {
        XCTAssertEqual(fridge.hotspotReading, "37°")
    }

    /// 0° is a real freezer setpoint, not "nothing set" as it is for an oven.
    func testAFreezerAtZeroShowsZero() {
        let freezer = HAEntityState(entityId: "water_heater.freezer", state: "Normal", attributes: [
            "operation_list": .array([.string("Normal"), .string("Turbo Freeze")]),
            "temperature": .number(0),
        ])
        XCTAssertEqual(freezer.hotspotReading, "0°")
        XCTAssertEqual(freezer.applianceDetails, ["Set to 0°"])
    }

    func testASensorShowsItsReadingAndOthersShowNothing() {
        let setting = HAEntityState(entityId: "sensor.fridge_setting", state: "37", attributes: ["unit_of_measurement": .string("°F")])
        XCTAssertEqual(setting.hotspotReading, "37°")
        XCTAssertNil(HAEntityState(entityId: "light.cans", state: "on", attributes: [:]).hotspotReading)
        XCTAssertNil(HAEntityState(entityId: "binary_sensor.door", state: "on", attributes: [:]).hotspotReading)
    }

    func testBinarySensorsReadByDeviceClass() {
        let door = { HAEntityState(entityId: "binary_sensor.fridge_door", state: $0, attributes: ["device_class": .string("door")]) }
        XCTAssertEqual(door("on").readableState, "Open")
        XCTAssertEqual(door("off").readableState, "Closed")

        let leak = HAEntityState(entityId: "binary_sensor.sink_leak", state: "off", attributes: ["device_class": .string("moisture")])
        XCTAssertEqual(leak.readableState, "Dry")

        let plain = HAEntityState(entityId: "binary_sensor.remote_enabled", state: "on", attributes: [:])
        XCTAssertEqual(plain.readableState, "On")
    }

    func testNumbersAndWordsRead() {
        let temperature = HAEntityState(entityId: "sensor.fridge_setting", state: "36.6", attributes: ["unit_of_measurement": .string("°F")])
        XCTAssertEqual(temperature.readableState, "37°")

        let filter = HAEntityState(entityId: "sensor.filter", state: "98", attributes: ["unit_of_measurement": .string("%")])
        XCTAssertEqual(filter.readableState, "98 %")

        let bucket = HAEntityState(entityId: "sensor.ice_bucket", state: "not_full", attributes: [:])
        XCTAssertEqual(bucket.readableState, "Not full")

        XCTAssertEqual(HAEntityState(entityId: "sensor.x", state: "unavailable", attributes: [:]).readableState, "Unavailable")
    }
}

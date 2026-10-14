import XCTest
@testable import Hassonic

/// The `thermostat` card: config, reading a climate entity, stepping, and
/// what it sends.
@MainActor
final class ThermostatTests: XCTestCase {

    private func card(_ yaml: String) throws -> DashboardThermostatConfiguration {
        let config = try AppConfigurationParser.parse("""
        version: 1
        pages:
          - id: home
            title: Home
            system_icon: house
            sections:
              - cards:
                  - type: thermostat
        \(yaml)
        """)
        guard case .thermostat(let card) = config.pages[0].sections[0].cards[0] else {
            XCTFail("expected a thermostat card")
            throw CancellationError()
        }
        return card
    }

    private func ecobee(state: String = "heat_cool", _ extra: [String: JSONValue] = [:]) -> HAEntityState {
        var attributes: [String: JSONValue] = [
            "hvac_modes": .array([.string("heat_cool"), .string("heat"), .string("cool"), .string("off")]),
            "min_temp": .number(44.6),
            "max_temp": .number(95),
            "current_temperature": .number(67.9),
            "target_temp_low": .number(68.4),
            "target_temp_high": .number(72.4),
            "current_humidity": .number(61),
            "hvac_action": .string("heating"),
        ]
        attributes.merge(extra) { $1 }
        return HAEntityState(entityId: "climate.my_ecobee", state: state, attributes: attributes)
    }

    // MARK: Config

    func testCardIsParsed() throws {
        let parsed = try card("""
                    entity: climate.my_ecobee
                    title: Thermostat
                    outside: weather.home
                    compact: true
        """)
        XCTAssertEqual(parsed, DashboardThermostatConfiguration(entity: "climate.my_ecobee", title: "Thermostat", outside: "weather.home", compact: true))
    }

    func testDefaults() throws {
        let parsed = try card("""
                    entity: climate.my_ecobee
        """)
        XCTAssertNil(parsed.outside)
        XCTAssertFalse(parsed.compact)
    }

    func testANonClimateEntityIsRejected() {
        XCTAssertThrowsError(try card("""
                    entity: sensor.my_ecobee_temperature
        """)) { error in
            XCTAssertEqual(error as? DashboardConfigurationError, .invalidEntity(entityID: "sensor.my_ecobee_temperature", cardType: "thermostat", expectedDomain: "climate"))
        }
    }

    func testOutsideMustBeWeatherOrSensor() throws {
        XCTAssertNoThrow(try card("""
                    entity: climate.x
                    outside: sensor.outdoor_temperature
        """))
        XCTAssertThrowsError(try card("""
                    entity: climate.x
                    outside: light.porch
        """)) { error in
            XCTAssertEqual(error as? DashboardConfigurationError, .invalidEntity(entityID: "light.porch", cardType: "thermostat", expectedDomain: "weather or sensor"))
        }
    }

    // MARK: Reading the entity

    func testReadsAnEcobeeInAuto() throws {
        let state = try XCTUnwrap(ThermostatState(ecobee()))
        XCTAssertEqual(state.mode, .auto)
        XCTAssertTrue(state.usesRange)
        XCTAssertEqual(state.action, .heating)
        XCTAssertEqual(state.current, 67.9)
        XCTAssertEqual(state.low, 68.4)
        XCTAssertEqual(state.high, 72.4)
        XCTAssertEqual(state.humidity, 61)
        XCTAssertEqual(state.modes, [.heat, .cool, .auto, .off])
    }

    func testActions() throws {
        XCTAssertEqual(ThermostatState(ecobee(["hvac_action": .string("cooling")]))?.action, .cooling)
        XCTAssertEqual(ThermostatState(ecobee(["hvac_action": .string("idle")]))?.action, .idle)
        XCTAssertEqual(ThermostatState(ecobee(state: "off", ["hvac_action": .null]))?.action, .off)
    }

    func testOnlyOfferedModesAreShown() throws {
        let state = try XCTUnwrap(ThermostatState(ecobee(["hvac_modes": .array([.string("heat"), .string("off")])])))
        XCTAssertEqual(state.modes, [.heat, .off])
    }

    /// Some thermostats call Auto `auto` and keep one setpoint in it.
    func testAThermostatWhoseAutoIsAuto() throws {
        let state = try XCTUnwrap(ThermostatState(HAEntityState(entityId: "climate.x", state: "auto", attributes: [
            "hvac_modes": .array([.string("auto"), .string("heat"), .string("off")]),
            "temperature": .number(70),
        ])))
        XCTAssertEqual(state.mode, .auto)
        XCTAssertFalse(state.usesRange)
        XCTAssertEqual(state.autoModeName, "auto")

        let client = MockHAClient()
        DashboardCardActionRouter.setThermostatMode(.auto, autoModeName: state.autoModeName, entityID: "climate.x", client: client)
        XCTAssertEqual(client.serviceCallLog.map(\.method), ["climateSetHvacMode:auto"])
    }

    func testUnavailableIsNil() {
        XCTAssertNil(ThermostatState(HAEntityState(entityId: "climate.x", state: "unavailable", attributes: [:])))
        XCTAssertNil(ThermostatState(nil))
    }

    // MARK: Stepping

    func testStepsLandOnWholeDegrees() {
        let state = ThermostatState(mode: .heat, action: .idle, minTemp: 45, maxTemp: 90)
        XCTAssertEqual(state.stepped(68.4, by: 1), 69)
        XCTAssertEqual(state.stepped(68.4, by: -1), 67)
        XCTAssertEqual(state.stepped(68, by: 1), 69)
        XCTAssertEqual(state.stepped(68.6, by: -1), 68)
        XCTAssertEqual(state.stepped(90, by: 1), 90)
        XCTAssertEqual(state.stepped(45, by: -1), 45)
    }

    func testRangeKeepsItsGap() {
        let state = ThermostatState(mode: .auto, action: .idle)
        let up = state.steppedRange(low: 70, high: 72, moving: .low, by: 1)
        XCTAssertEqual(up.low, 71)
        XCTAssertEqual(up.high, 73)
        let down = state.steppedRange(low: 70, high: 72, moving: .high, by: -1)
        XCTAssertEqual(down.low, 69)
        XCTAssertEqual(down.high, 71)
        let roomy = state.steppedRange(low: 68, high: 74, moving: .low, by: 1)
        XCTAssertEqual(roomy.low, 69)
        XCTAssertEqual(roomy.high, 74)
    }

    // MARK: Sending

    func testServiceCalls() {
        let client = MockHAClient()
        DashboardCardActionRouter.setThermostat(70, entityID: "climate.my_ecobee", client: client)
        DashboardCardActionRouter.setThermostatRange(low: 68, high: 73, entityID: "climate.my_ecobee", client: client)
        DashboardCardActionRouter.setThermostatMode(.auto, entityID: "climate.my_ecobee", client: client)
        XCTAssertEqual(client.serviceCallLog.map(\.method), [
            "climateSetTemperature:70.0", "climateSetTemperatureRange:68.0-73.0", "climateSetHvacMode:heat_cool",
        ])
    }

    func testOutsideTemperature() {
        XCTAssertEqual(DashboardCardActionRouter.outsideTemperature(HAEntityState(entityId: "weather.home", state: "cloudy", attributes: ["temperature": .number(53)])), 53)
        XCTAssertEqual(DashboardCardActionRouter.outsideTemperature(HAEntityState(entityId: "sensor.out", state: "51.4", attributes: [:])), 51.4)
        XCTAssertNil(DashboardCardActionRouter.outsideTemperature(HAEntityState(entityId: "sensor.out", state: "unavailable", attributes: [:])))
    }

    func testTheEncodedServiceDataUsesHANames() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let range = HAClimateSetTemperatureMessage(id: 1, target: .init(entityId: "climate.x"), serviceData: .init(targetTempLow: 68, targetTempHigh: 73))
        let json = try XCTUnwrap(String(data: encoder.encode(range), encoding: .utf8))
        XCTAssertTrue(json.contains("\"target_temp_low\":68"), json)
        XCTAssertTrue(json.contains("\"target_temp_high\":73"), json)
        XCTAssertFalse(json.contains("\"temperature\""), json)
        let mode = HAClimateSetHvacModeMessage(id: 2, target: .init(entityId: "climate.x"), serviceData: .init(hvacMode: "heat"))
        XCTAssertTrue(try XCTUnwrap(String(data: encoder.encode(mode), encoding: .utf8)).contains("\"hvac_mode\":\"heat\""))
    }
}

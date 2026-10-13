import XCTest
@testable import Hassonic

@MainActor
final class SecurityViewTests: XCTestCase {

    // MARK: - Status text

    func testStatusTextDisarmed() {
        XCTAssertEqual(alarmStatusText(for: "disarmed"), "Disarmed")
    }

    func testStatusTextArmedHome() {
        XCTAssertEqual(alarmStatusText(for: "armed_home"), "Armed – Home")
    }

    func testStatusTextArmedAway() {
        XCTAssertEqual(alarmStatusText(for: "armed_away"), "Armed – Away")
    }

    func testStatusTextArmedNight() {
        XCTAssertEqual(alarmStatusText(for: "armed_night"), "Armed – Night")
    }

    func testStatusTextArmedVacation() {
        XCTAssertEqual(alarmStatusText(for: "armed_vacation"), "Armed – Vacation")
    }

    func testStatusTextArming() {
        XCTAssertEqual(alarmStatusText(for: "arming"), "Arming…")
    }

    func testStatusTextPending() {
        XCTAssertEqual(alarmStatusText(for: "pending"), "Pending")
    }

    func testStatusTextTriggered() {
        XCTAssertEqual(alarmStatusText(for: "triggered"), "Triggered!")
    }

    func testStatusTextDisarming() {
        XCTAssertEqual(alarmStatusText(for: "disarming"), "Disarming…")
    }

    func testStatusTextNilReturnsUnknown() {
        XCTAssertEqual(alarmStatusText(for: nil), "Unknown")
    }

    /// An unmapped state should read like the mapped ones do — human text,
    /// not snake_case. This expected "Some_state" and the implementation
    /// produced "Some_State", because `.capitalized` treats "_" as a word
    /// boundary; neither was what a person wants to read.
    func testUnmappedStateIsHumanized() {
        XCTAssertEqual(alarmStatusText(for: "some_state"), "Some state")
        XCTAssertEqual(alarmStatusText(for: "armed_custom_bypass"), "Armed custom bypass")
        XCTAssertEqual(alarmStatusText(for: "triggered_by_zone_3"), "Triggered by zone 3")
    }

    func testHumanizingHandlesEdgeCases() {
        XCTAssertEqual(alarmStatusText(for: "ready"), "Ready")
        XCTAssertEqual(alarmStatusText(for: ""), "")
        // Mapped states keep their own wording, dashes and ellipses intact.
        XCTAssertEqual(alarmStatusText(for: "armed_home"), "Armed – Home")
        XCTAssertEqual(alarmStatusText(for: "disarming"), "Disarming…")
    }

    // MARK: - Status icon

    func testStatusIconDisarmed() {
        XCTAssertEqual(alarmStatusIcon(for: "disarmed"), "lock.open.fill")
    }

    func testStatusIconTriggered() {
        XCTAssertEqual(alarmStatusIcon(for: "triggered"), "exclamationmark.triangle.fill")
    }

    func testStatusIconArmed() {
        XCTAssertEqual(alarmStatusIcon(for: "armed_home"), "lock.fill")
    }

    func testStatusIconNil() {
        XCTAssertEqual(alarmStatusIcon(for: nil), "lock.fill")
    }

    // MARK: - Available modes filtering

    func testAvailableModesNoneWhenFeaturesZero() {
        XCTAssertTrue(alarmAvailableModes(supportedFeatures: 0).isEmpty)
    }

    func testAvailableModesHomeBit() {
        let modes = alarmAvailableModes(supportedFeatures: 1)
        XCTAssertEqual(modes, [.home])
    }

    func testAvailableModesAwayBit() {
        let modes = alarmAvailableModes(supportedFeatures: 2)
        XCTAssertEqual(modes, [.away])
    }

    func testAvailableModesNightBit() {
        let modes = alarmAvailableModes(supportedFeatures: 4)
        XCTAssertEqual(modes, [.night])
    }

    func testAvailableModesVacationBit() {
        let modes = alarmAvailableModes(supportedFeatures: 32)
        XCTAssertEqual(modes, [.vacation])
    }

    func testAvailableModesAllBits() {
        let modes = alarmAvailableModes(supportedFeatures: 1 | 2 | 4 | 32)
        XCTAssertEqual(modes, AlarmMode.allCases)
    }

    func testAvailableModesCombined() {
        let modes = alarmAvailableModes(supportedFeatures: 1 | 4)
        XCTAssertEqual(modes, [.home, .night])
    }

    // MARK: - Action routing via MockHAClient

    func testArmHomeCallsCorrectService() {
        let mock = MockHAClient()
        mock.simulateConnected()
        let entityId = "alarm_control_panel.home_security_system"
        mock.armHome(entityId)
        XCTAssertEqual(mock.serviceCallLog.last?.method, "armHome")
        XCTAssertEqual(mock.serviceCallLog.last?.entityId, entityId)
    }

    func testArmAwayCallsCorrectService() {
        let mock = MockHAClient()
        mock.simulateConnected()
        let entityId = "alarm_control_panel.home_security_system"
        mock.armAway(entityId)
        XCTAssertEqual(mock.serviceCallLog.last?.method, "armAway")
    }

    func testArmNightCallsCorrectService() {
        let mock = MockHAClient()
        mock.simulateConnected()
        mock.armNight("alarm_control_panel.home_security_system")
        XCTAssertEqual(mock.serviceCallLog.last?.method, "armNight")
    }

    func testArmVacationCallsCorrectService() {
        let mock = MockHAClient()
        mock.simulateConnected()
        mock.armVacation("alarm_control_panel.home_security_system")
        XCTAssertEqual(mock.serviceCallLog.last?.method, "armVacation")
    }

    func testDisarmCallsCorrectService() {
        let mock = MockHAClient()
        mock.simulateConnected()
        mock.disarmAlarm("alarm_control_panel.home_security_system")
        XCTAssertEqual(mock.serviceCallLog.last?.method, "disarmAlarm")
    }
}

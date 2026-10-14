import Foundation
import Combine
@testable import Hassonic

/// A test double for `HAClientProtocol` that never opens a real WebSocket.
///
/// ## Usage
///
/// ```swift
/// let mock = MockHAClient()
///
/// // Simulate a successful connection and populated entities:
/// mock.simulateConnected(entities: MockHAClient.Fixtures.mediaPlayerEntities)
///
/// // Simulate an authentication failure:
/// mock.simulateAuthError()
///
/// // Simulate a connection failure:
/// mock.simulateFailure("Network unreachable")
///
/// // Inspect recorded calls:
/// XCTAssertTrue(mock.calledDisconnect)
/// XCTAssertEqual(mock.volumeSetCalls.last?.level, 0.5)
/// ```
@MainActor
final class MockHAClient: ObservableObject, HAClientProtocol {

    // MARK: - Protocol-required published state

    @Published private(set) var connectionState: HAConnectionState = .disconnected
    @Published private(set) var entities: [HAEntityState] = []
    @Published private(set) var baseURLString: String = ""
    @Published private(set) var accessToken: String?

    // MARK: - Call recording

    private(set) var connectCalls: [(baseURL: URL, accessToken: String)] = []
    private(set) var calledDisconnect = false
    private(set) var volumeSetCalls: [(entityId: String, level: Double)] = []
    private(set) var muteCalls: [(entityId: String, muted: Bool)] = []
    private(set) var selectSourceCalls: [(entityId: String, source: String)] = []
    private(set) var playMediaCalls: [(entityId: String, contentType: String, contentId: String)] = []
    private(set) var serviceCallLog: [(method: String, entityId: String)] = []

    /// Controls what `selectSourceConfirmed` returns. Defaults to `.confirmed`.
    var selectSourceConfirmedResult: SelectSourceResult = .confirmed
    /// When set, `selectSourceConfirmed` waits this long before returning (simulates HA latency).
    var selectSourceConfirmedDelay: Duration? = nil

    /// Controls what `browseMedia` returns. Defaults to a successful empty result.
    var browseMediaResult: HABrowseMediaResult = HABrowseMediaResult(success: true, result: nil, error: nil)

    private(set) var claimSpeakerCalls: [(config: SpeakerClaimConfig, account: String, speaker: String)] = []
    /// Controls what `claimSpeaker` returns. Defaults to confirmed.
    var claimSpeakerResult: SpeakerClaimOutcome = .confirmed(usedDevice: "Mock Device")

    // MARK: - Simulation helpers

    func simulateConnected(entities: [HAEntityState] = []) {
        connectionState = .connected
        self.entities = entities
    }

    func simulateAuthError() {
        connectionState = .failed("Authentication failed. Check your access token.")
    }

    func simulateFailure(_ message: String = "Simulated failure") {
        connectionState = .failed(message)
    }

    func simulateDisconnected() {
        connectionState = .disconnected
        entities = []
    }

    // MARK: - HAClientProtocol

    func entity(_ entityId: String) -> HAEntityState? {
        entities.first { $0.entityId == entityId }
    }

    func connect(baseURL: URL, accessToken: String) {
        connectCalls.append((baseURL, accessToken))
        baseURLString = baseURL.absoluteString
        self.accessToken = accessToken
        connectionState = .connecting
    }

    func disconnect() {
        calledDisconnect = true
        connectionState = .disconnected
        entities = []
    }

    func setVolume(_ entityId: String, level: Double) {
        volumeSetCalls.append((entityId, level))
    }

    func setMuted(_ entityId: String, muted: Bool) {
        muteCalls.append((entityId, muted))
    }

    func selectSource(_ entityId: String, source: String) {
        selectSourceCalls.append((entityId, source))
    }

    func selectSourceConfirmed(_ entityId: String, source: String) async -> SelectSourceResult {
        await selectSourceConfirmed(entityId, source: source, timeout: .seconds(5))
    }

    func selectSourceConfirmed(_ entityId: String, source: String, timeout: Duration) async -> SelectSourceResult {
        selectSourceCalls.append((entityId, source))
        if let delay = selectSourceConfirmedDelay {
            try? await Task.sleep(for: delay)
        }
        return selectSourceConfirmedResult
    }

    func browseMedia(entityId: String, mediaContentType: String?, mediaContentId: String?) async -> HABrowseMediaResult {
        browseMediaResult
    }

    func claimSpeaker(using config: SpeakerClaimConfig, account: String, speaker: String, contentName: String?, onStatus: @escaping (String) -> Void) async -> SpeakerClaimOutcome {
        claimSpeakerCalls.append((config, account, speaker))
        return claimSpeakerResult
    }

    func playMedia(_ entityId: String, contentType: String, contentId: String) {
        playMediaCalls.append((entityId, contentType, contentId))
    }

    func mediaPlayPause(_ entityId: String) { serviceCallLog.append(("mediaPlayPause", entityId)) }
    func mediaNextTrack(_ entityId: String) { serviceCallLog.append(("mediaNextTrack", entityId)) }
    func mediaPreviousTrack(_ entityId: String) { serviceCallLog.append(("mediaPreviousTrack", entityId)) }
    func turnOn(_ entityId: String) { serviceCallLog.append(("turnOn", entityId)) }
    func turnOff(_ entityId: String) { serviceCallLog.append(("turnOff", entityId)) }

    func armHome(_ entityId: String) { serviceCallLog.append(("armHome", entityId)) }
    func armAway(_ entityId: String) { serviceCallLog.append(("armAway", entityId)) }
    func armNight(_ entityId: String) { serviceCallLog.append(("armNight", entityId)) }
    func armVacation(_ entityId: String) { serviceCallLog.append(("armVacation", entityId)) }
    func disarmAlarm(_ entityId: String) { serviceCallLog.append(("disarmAlarm", entityId)) }

    func lightTurnOn(_ entityId: String) { serviceCallLog.append(("lightTurnOn", entityId)) }
    func lightTurnOff(_ entityId: String) { serviceCallLog.append(("lightTurnOff", entityId)) }
    func coverOpen(_ entityId: String) { serviceCallLog.append(("coverOpen", entityId)) }
    func coverClose(_ entityId: String) { serviceCallLog.append(("coverClose", entityId)) }
    func coverStop(_ entityId: String) { serviceCallLog.append(("coverStop", entityId)) }
    func coverSetPosition(_ entityId: String, position: Int) { serviceCallLog.append(("coverSetPosition:\(position)", entityId)) }

    func remoteSendCommand(_ entityId: String, command: String) { serviceCallLog.append(("remoteSendCommand:\(command)", entityId)) }
    func remoteSendText(_ entityId: String, text: String) { serviceCallLog.append(("remoteSendText:\(text)", entityId)) }
    func runScript(_ entityId: String) { serviceCallLog.append(("runScript", entityId)) }
    func toggle(_ entityId: String) { serviceCallLog.append(("toggle", entityId)) }
    func climateSetTemperature(_ entityId: String, temperature: Double) { serviceCallLog.append(("climateSetTemperature:\(temperature)", entityId)) }
    func climateSetTemperatureRange(_ entityId: String, low: Double, high: Double) { serviceCallLog.append(("climateSetTemperatureRange:\(low)-\(high)", entityId)) }
    func climateSetHvacMode(_ entityId: String, mode: String) { serviceCallLog.append(("climateSetHvacMode:\(mode)", entityId)) }

    // MARK: - Deterministic fixture data

    enum Fixtures {
        /// A media_player entity in the 'playing' state with typical attributes.
        static let mediaPlayerPlaying = HAEntityState(
            entityId: "media_player.living_room",
            state: "playing",
            attributes: [
                "friendly_name": .string("Living Room"),
                "volume_level": .number(0.4),
                "is_volume_muted": .bool(false),
                "source": .string("Spotify"),
                "source_list": .array([.string("Spotify"), .string("AirPlay")])
            ]
        )

        /// A media_player entity in the 'off' state.
        static let mediaPlayerOff = HAEntityState(
            entityId: "media_player.bedroom",
            state: "off",
            attributes: [
                "friendly_name": .string("Bedroom"),
                "volume_level": .number(0.0),
                "is_volume_muted": .bool(false)
            ]
        )

        /// An alarm_control_panel entity in the 'disarmed' state.
        static let alarmDisarmed = HAEntityState(
            entityId: "alarm_control_panel.home",
            state: "disarmed",
            attributes: [
                "friendly_name": .string("Home Alarm"),
                "code_format": .string("number")
            ]
        )

        /// An alarm_control_panel entity in the 'armed_home' state.
        static let alarmArmedHome = HAEntityState(
            entityId: "alarm_control_panel.home",
            state: "armed_home",
            attributes: [
                "friendly_name": .string("Home Alarm"),
                "code_format": .string("number")
            ]
        )

        static let mediaPlayerEntities: [HAEntityState] = [mediaPlayerPlaying, mediaPlayerOff]
    }
}

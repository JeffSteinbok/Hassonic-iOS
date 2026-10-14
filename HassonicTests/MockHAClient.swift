import Foundation
import Combine
@testable import Hassonic

/// A test double for `HAClientProtocol` that never opens a real WebSocket.
/// Every call is recorded in `serviceCallLog`:
///
/// ```swift
/// let mock = MockHAClient()
/// mock.simulateConnected(entities: [...])
/// DashboardCardActionRouter.setLight(true, entityID: "light.porch", client: mock)
/// XCTAssertEqual(mock.serviceCallLog.map(\.method), ["lightTurnOn"])
/// ```
@MainActor
final class MockHAClient: ObservableObject, HAClientProtocol {

    @Published private(set) var connectionState: HAConnectionState = .disconnected
    @Published private(set) var entities: [HAEntityState] = []
    @Published private(set) var baseURLString: String = ""
    @Published private(set) var accessToken: String?

    private(set) var serviceCallLog: [(method: String, entityId: String)] = []

    func simulateConnected(entities: [HAEntityState] = []) {
        connectionState = .connected
        self.entities = entities
    }

    // MARK: - HAClientProtocol

    func entity(_ entityId: String) -> HAEntityState? {
        entities.first { $0.entityId == entityId }
    }

    func connect(baseURL: URL, accessToken: String) {
        baseURLString = baseURL.absoluteString
        self.accessToken = accessToken
        connectionState = .connecting
    }

    func disconnect() {
        connectionState = .disconnected
        entities = []
    }

    func setVolume(_ entityId: String, level: Double) { serviceCallLog.append(("setVolume:\(level)", entityId)) }
    func setMuted(_ entityId: String, muted: Bool) { serviceCallLog.append(("setMuted:\(muted)", entityId)) }
    func selectSource(_ entityId: String, source: String) { serviceCallLog.append(("selectSource:\(source)", entityId)) }

    func selectSourceConfirmed(_ entityId: String, source: String) async -> SelectSourceResult {
        await selectSourceConfirmed(entityId, source: source, timeout: .seconds(5))
    }

    func selectSourceConfirmed(_ entityId: String, source: String, timeout: Duration) async -> SelectSourceResult {
        serviceCallLog.append(("selectSourceConfirmed:\(source)", entityId))
        return .confirmed
    }

    func browseMedia(entityId: String, mediaContentType: String?, mediaContentId: String?) async -> HABrowseMediaResult {
        HABrowseMediaResult(success: true, result: nil, error: nil)
    }

    func claimSpeaker(using config: SpeakerClaimConfig, account: String, speaker: String, contentName: String?, onStatus: @escaping (String) -> Void) async -> SpeakerClaimOutcome {
        serviceCallLog.append(("claimSpeaker:\(speaker)", account))
        return .confirmed(usedDevice: "Mock Device")
    }

    func playMedia(_ entityId: String, contentType: String, contentId: String) {
        serviceCallLog.append(("playMedia:\(contentType):\(contentId)", entityId))
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
}

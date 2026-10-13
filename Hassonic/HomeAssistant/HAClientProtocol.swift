import Foundation
import Combine

enum SelectSourceResult {
    case alreadyActive
    case confirmed
    case timeout
    case error(String)
}

/// Result of claiming a speaker for a media account — binding it so the
/// account can cast to it.
///
/// The mechanism is a voice-assistant round trip today, because the provider
/// this was built against offers no service to rebind a speaker. That is an
/// implementation detail of the client, deliberately not named here: this
/// protocol is what every view and test sees.
enum SpeakerClaimOutcome {
    /// A device confirmed the claim and was told to start playback.
    case confirmed(usedDevice: String)
    /// Every configured device failed (wrong account even after a retry, or
    /// no response at all) — `reason` is a human-readable summary for the error UI.
    case failed(reason: String)
}

/// Surface area of `HAWebSocketClient` that ViewModels and views depend on.
/// Conforming to this protocol is sufficient to replace the live client in tests.
@MainActor
protocol HAClientProtocol: ObservableObject {
    var connectionState: HAConnectionState { get }
    var entities: [HAEntityState] { get }
    var baseURLString: String { get }
    var accessToken: String? { get }

    func entity(_ entityId: String) -> HAEntityState?
    func connect(baseURL: URL, accessToken: String)
    func disconnect()

    func setVolume(_ entityId: String, level: Double)
    func setMuted(_ entityId: String, muted: Bool)
    func selectSource(_ entityId: String, source: String)
    func selectSourceConfirmed(_ entityId: String, source: String, timeout: Duration) async -> SelectSourceResult
    /// Default-timeout convenience — same 5s window used for the initial
    /// "is this zone already on this account" probe.
    func selectSourceConfirmed(_ entityId: String, source: String) async -> SelectSourceResult
    func claimSpeaker(using config: SpeakerClaimConfig, account: String, speaker: String, contentName: String?, onStatus: @escaping (String) -> Void) async -> SpeakerClaimOutcome
    func browseMedia(entityId: String, mediaContentType: String?, mediaContentId: String?) async -> HABrowseMediaResult
    func playMedia(_ entityId: String, contentType: String, contentId: String)
    func mediaPlayPause(_ entityId: String)
    func mediaNextTrack(_ entityId: String)
    func mediaPreviousTrack(_ entityId: String)
    func turnOn(_ entityId: String)
    func turnOff(_ entityId: String)

    func armHome(_ entityId: String)
    func armAway(_ entityId: String)
    func armNight(_ entityId: String)
    func armVacation(_ entityId: String)
    func disarmAlarm(_ entityId: String)

    func lightTurnOn(_ entityId: String)
    func lightTurnOff(_ entityId: String)
    func coverOpen(_ entityId: String)
    func coverClose(_ entityId: String)
    func coverStop(_ entityId: String)
    func coverSetPosition(_ entityId: String, position: Int)

    func remoteSendCommand(_ entityId: String, command: String)
    func runScript(_ entityId: String)
    /// `<domain>.toggle`, for any entity that has one.
    func toggle(_ entityId: String)

    /// One setpoint, for heat or cool.
    func climateSetTemperature(_ entityId: String, temperature: Double)
    /// The heat and cool setpoints together, for heat_cool.
    func climateSetTemperatureRange(_ entityId: String, low: Double, high: Double)
    func climateSetHvacMode(_ entityId: String, mode: String)
}

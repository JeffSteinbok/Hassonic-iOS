import Foundation

/// Service calls: one `call_service` message each, fire and forget.
extension HAWebSocketClient {
    func setVolume(_ entityId: String, level: Double) {
        send(HAVolumeSetMessage(id: nextId(), target: .init(entityId: entityId), serviceData: .init(volumeLevel: level)))
    }

    func setMuted(_ entityId: String, muted: Bool) {
        send(HAVolumeMuteMessage(id: nextId(), target: .init(entityId: entityId), serviceData: .init(isVolumeMuted: muted)))
    }

    func selectSource(_ entityId: String, source: String) {
        send(HASelectSourceMessage(id: nextId(), target: .init(entityId: entityId), serviceData: .init(source: source)))
    }

    func playMedia(_ entityId: String, contentType: String, contentId: String) {
        send(HAPlayMediaMessage(id: nextId(), target: .init(entityId: entityId), serviceData: .init(mediaContentId: contentId, mediaContentType: contentType)))
    }

    func browseMedia(entityId: String, mediaContentType: String? = nil, mediaContentId: String? = nil) async -> HABrowseMediaResult {
        let id = nextId()
        return await withCheckedContinuation { continuation in
            browseMediaRequests[id] = continuation
            send(HABrowseMediaMessage(id: id,
                                      entityId: entityId,
                                      mediaContentType: mediaContentType,
                                      mediaContentId: mediaContentId))
        }
    }

    func mediaPlayPause(_ entityId: String) { callService(domain: "media_player", service: "media_play_pause", entityId: entityId) }
    func mediaNextTrack(_ entityId: String) { callService(domain: "media_player", service: "media_next_track", entityId: entityId) }
    func mediaPreviousTrack(_ entityId: String) { callService(domain: "media_player", service: "media_previous_track", entityId: entityId) }
    func turnOn(_ entityId: String) { callService(domain: "media_player", service: "turn_on", entityId: entityId) }
    func turnOff(_ entityId: String) { callService(domain: "media_player", service: "turn_off", entityId: entityId) }

    func armHome(_ entityId: String) { callService(domain: "alarm_control_panel", service: "alarm_arm_home", entityId: entityId) }
    func armAway(_ entityId: String) { callService(domain: "alarm_control_panel", service: "alarm_arm_away", entityId: entityId) }
    func armNight(_ entityId: String) { callService(domain: "alarm_control_panel", service: "alarm_arm_night", entityId: entityId) }
    func armVacation(_ entityId: String) { callService(domain: "alarm_control_panel", service: "alarm_arm_vacation", entityId: entityId) }
    func disarmAlarm(_ entityId: String) { callService(domain: "alarm_control_panel", service: "alarm_disarm", entityId: entityId) }

    func lightTurnOn(_ entityId: String) { callService(domain: "light", service: "turn_on", entityId: entityId) }
    func lightTurnOff(_ entityId: String) { callService(domain: "light", service: "turn_off", entityId: entityId) }
    func coverOpen(_ entityId: String) { callService(domain: "cover", service: "open_cover", entityId: entityId) }
    func coverClose(_ entityId: String) { callService(domain: "cover", service: "close_cover", entityId: entityId) }
    func coverStop(_ entityId: String) { callService(domain: "cover", service: "stop_cover", entityId: entityId) }
    func coverSetPosition(_ entityId: String, position: Int) {
        send(HACoverSetPositionMessage(id: nextId(), target: .init(entityId: entityId), serviceData: .init(position: position)))
    }

    func remoteSendCommand(_ entityId: String, command: String) {
        send(HARemoteSendCommandMessage(id: nextId(), target: .init(entityId: entityId), serviceData: .init(command: command)))
    }
    func runScript(_ entityId: String) { callService(domain: "script", service: "turn_on", entityId: entityId) }
    func toggle(_ entityId: String) {
        guard let domain = entityId.split(separator: ".").first else { return }
        callService(domain: String(domain), service: "toggle", entityId: entityId)
    }
    func climateSetTemperature(_ entityId: String, temperature: Double) {
        send(HAClimateSetTemperatureMessage(id: nextId(), target: .init(entityId: entityId), serviceData: .init(temperature: temperature)))
    }

    func climateSetTemperatureRange(_ entityId: String, low: Double, high: Double) {
        send(HAClimateSetTemperatureMessage(id: nextId(), target: .init(entityId: entityId), serviceData: .init(targetTempLow: low, targetTempHigh: high)))
    }

    func climateSetHvacMode(_ entityId: String, mode: String) {
        send(HAClimateSetHvacModeMessage(id: nextId(), target: .init(entityId: entityId), serviceData: .init(hvacMode: mode)))
    }

    /// `<domain>.<service>` on one entity, with data: `fan.set_percentage`,
    /// `light.turn_on` with a brightness, and the like.
    func callService(domain: String, service: String, entityId: String, data: [String: JSONValue]) {
        send(HAServiceDataMessage(id: nextId(), domain: domain, service: service, target: .init(entityId: entityId), serviceData: data))
    }

    func callService(domain: String, service: String, entityId: String) {
        send(HACallServiceMessage(id: nextId(), domain: domain, service: service, target: .init(entityId: entityId)))
    }
}

import Foundation

enum DashboardCoverAction: Equatable {
    case open
    case close
    case stop
    case setPosition(Int)
}

@MainActor
enum DashboardCardActionRouter {
    static func setLight<Client: HAClientProtocol>(
        _ isOn: Bool,
        entityID: String,
        client: Client
    ) {
        if isOn {
            client.lightTurnOn(entityID)
        } else {
            client.lightTurnOff(entityID)
        }
    }

    static func performCoverAction<Client: HAClientProtocol>(
        _ action: DashboardCoverAction,
        entityID: String,
        client: Client
    ) {
        switch action {
        case .open:
            client.coverOpen(entityID)
        case .close:
            client.coverClose(entityID)
        case .stop:
            client.coverStop(entityID)
        case .setPosition(let position):
            client.coverSetPosition(entityID, position: position)
        }
    }

    static func setAlarmMode<Client: HAClientProtocol>(
        _ mode: AlarmMode,
        entityID: String,
        client: Client
    ) {
        switch mode {
        case .home: client.armHome(entityID)
        case .away: client.armAway(entityID)
        case .night: client.armNight(entityID)
        case .vacation: client.armVacation(entityID)
        }
    }

    static func disarm<Client: HAClientProtocol>(entityID: String, client: Client) {
        client.disarmAlarm(entityID)
    }

    /// Whether the last fallback play/pause sent was a pause, per Samsung
    /// remote with no media player to toggle for it.
    private static var lastSamsungPlaybackWasPause: [String: Bool] = [:]

    /// Sends `actions` now. Opening an app may have to wait for the TV to
    /// turn on, so it finishes in the background; see `run` to wait for it.
    static func perform<Client: HAClientProtocol>(_ actions: [TVRemoteAction], client: Client) {
        for action in actions {
            if case .openApp(let mediaPlayer, let source, let powerScript) = action {
                Task { await openApp(source, on: mediaPlayer, powerScript: powerScript, client: client) }
            } else {
                send(action, client: client)
            }
        }
    }

    /// Sends `actions` in order and returns once they're all sent, for a
    /// Siri or Lock Screen press that iOS may suspend once it returns.
    static func run<Client: HAClientProtocol>(_ actions: [TVRemoteAction], client: Client) async {
        for action in actions {
            if case .openApp(let mediaPlayer, let source, let powerScript) = action {
                await openApp(source, on: mediaPlayer, powerScript: powerScript, client: client)
            } else {
                send(action, client: client)
            }
        }
    }

    /// How long a TV may take to report itself on after being turned on.
    static let tvWakeTimeout: Duration = .seconds(20)
    /// After it reports on, its network remote needs a moment before it
    /// takes an app launch.
    static let tvWakeSettle: Duration = .seconds(2)

    /// Opens `source` on the TV, turning it on first if it's off.
    static func openApp<Client: HAClientProtocol>(
        _ source: String, on mediaPlayer: String, powerScript: String?, client: Client,
        sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async {
        func isOff() -> Bool { ["off", "standby"].contains(client.entity(mediaPlayer)?.state) }
        if isOff() {
            if let powerScript {
                client.runScript(powerScript)
            } else {
                client.turnOn(mediaPlayer)
            }
            let step: Duration = .milliseconds(500)
            var waited: Duration = .zero
            while isOff(), waited < tvWakeTimeout {
                await sleep(step)
                waited += step
            }
            // Still off: send it anyway, which some TVs wake for.
            await sleep(tvWakeSettle)
        }
        client.selectSource(mediaPlayer, source: source)
    }

    private static func send<Client: HAClientProtocol>(_ action: TVRemoteAction, client: Client) {
        switch action {
        case .send(let remote, let command):
            client.remoteSendCommand(remote, command: command)
        case .mediaPlayPause(let mediaPlayer):
            client.mediaPlayPause(mediaPlayer)
        case .samsungPlayPause(let remote):
            let pause = !(lastSamsungPlaybackWasPause[remote] ?? false)
            lastSamsungPlaybackWasPause[remote] = pause
            client.remoteSendCommand(remote, command: pause ? "KEY_PAUSE" : "KEY_PLAY")
        case .sendText(let remote, let text):
            client.remoteSendText(remote, text: text)
        case .runScript(let script):
            client.runScript(script)
        case .openApp(let mediaPlayer, let source, _):
            client.selectSource(mediaPlayer, source: source)
        }
    }


    // MARK: Thermostat

    static func setThermostat<Client: HAClientProtocol>(_ temperature: Double, entityID: String, client: Client) {
        client.climateSetTemperature(entityID, temperature: temperature)
    }

    static func setThermostatRange<Client: HAClientProtocol>(low: Double, high: Double, entityID: String, client: Client) {
        client.climateSetTemperatureRange(entityID, low: low, high: high)
    }

    /// `autoModeName` is what this thermostat calls Auto (see `ThermostatState`).
    static func setThermostatMode<Client: HAClientProtocol>(_ mode: ThermostatState.Mode, autoModeName: String = ThermostatState.Mode.auto.rawValue, entityID: String, client: Client) {
        client.climateSetHvacMode(entityID, mode: mode == .auto ? autoModeName : mode.rawValue)
    }

    /// A `weather.*` entity's `temperature`, or a `sensor.*` entity's state.
    static func outsideTemperature(_ entity: HAEntityState?) -> Double? {
        guard let entity, entity.isAvailable else { return nil }
        if entity.entityId.hasPrefix("weather.") {
            return entity.attributeDouble("temperature")
        }
        return Double(entity.state)
    }
}

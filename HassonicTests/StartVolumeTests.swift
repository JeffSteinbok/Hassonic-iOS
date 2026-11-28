import XCTest
@testable import Hassonic

/// Speaker volume when music starts: put back what the handoff lowered,
/// raise to a floor, reset pins, never turn anything down.
@MainActor
final class StartVolumeTests: XCTestCase {

    // MARK: - Fixtures

    private func speaker(_ id: String, enabled: Bool = true, pin: Double? = nil, proxy: String? = nil) -> MusicZone {
        MusicZone(entityId: id, displayName: id, kind: .speaker, sourceName: id, icon: "hifispeaker.fill",
                  memberEntityIds: [], isEnabled: enabled, defaultVolume: pin,
                  proxy: proxy.map { ProxyDevice(entityId: $0, inputSource: "ECHO DOT") })
    }

    private func group(_ id: String, members: [String]) -> MusicZone {
        MusicZone(entityId: id, displayName: id, kind: .group, sourceName: "Downstairs", icon: "stairs",
                  memberEntityIds: members, isEnabled: true, defaultVolume: nil, proxy: nil)
    }

    private lazy var zones: [MusicZone] = [
        speaker("media_player.kitchen"),
        speaker("media_player.living_room"),
        speaker("media_player.home_theater", pin: 0.7, proxy: "media_player.avr"),
        speaker("media_player.family_room", enabled: false),
    ]

    private lazy var downstairs = group("media_player.downstairs", members: [
        "media_player.kitchen", "media_player.living_room", "media_player.home_theater", "media_player.family_room",
    ])

    private func levels(_ map: [String: Double]) -> (String) -> Double? { { map[$0] } }

    private func corrections(before: [String: Double], now: [String: Double],
                             settings: StartVolumeConfiguration = .init()) -> [String: Double] {
        let changes = StartVolume.corrections(for: StartVolume.targets(for: downstairs, zones: zones),
                                              before: before, level: levels(now), settings: settings)
        return Dictionary(uniqueKeysWithValues: changes.map { ($0.entityId, $0.level) })
    }

    // MARK: - Targets

    func testAGroupTargetsItsEnabledMembersWithTheirPins() {
        let targets = StartVolume.targets(for: downstairs, zones: zones)
        XCTAssertEqual(targets, [
            .init(entityId: "media_player.kitchen", pin: nil),
            .init(entityId: "media_player.living_room", pin: nil),
            .init(entityId: "media_player.home_theater", pin: 0.7),
        ], "a disabled member is left alone")
    }

    func testASpeakerTargetsItselfNotItsProxy() {
        let targets = StartVolume.targets(for: zones[2], zones: zones)
        XCTAssertEqual(targets.map(\.entityId), ["media_player.home_theater"],
                       "the receiver's volume is the one set by hand; the start never touches it")
    }

    func testAMemberNotInTheConfigIsStillATarget() {
        let targets = StartVolume.targets(for: group("media_player.g", members: ["media_player.other"]), zones: zones)
        XCTAssertEqual(targets, [.init(entityId: "media_player.other", pin: nil)])
    }

    // MARK: - Corrections

    func testWhatTheHandoffLoweredIsPutBack() {
        let result = corrections(before: ["media_player.kitchen": 0.45, "media_player.living_room": 0.3],
                                 now: ["media_player.kitchen": 0.23, "media_player.living_room": 0.3,
                                       "media_player.home_theater": 0.7])
        XCTAssertEqual(result, ["media_player.kitchen": 0.45])
    }

    func testNothingIsEverTurnedDown() {
        let result = corrections(before: ["media_player.kitchen": 0.3],
                                 now: ["media_player.kitchen": 0.6, "media_player.living_room": 0.5,
                                       "media_player.home_theater": 0.7])
        XCTAssertEqual(result, [:], "a speaker the handoff turned up stays up")
    }

    func testASpeakerUnderTheFloorIsRaisedToIt() {
        let result = corrections(before: ["media_player.kitchen": 0.05],
                                 now: ["media_player.kitchen": 0.05, "media_player.living_room": 0.1,
                                       "media_player.home_theater": 0.7],
                                 settings: .init(restore: true, floor: 0.25))
        XCTAssertEqual(result, ["media_player.kitchen": 0.25, "media_player.living_room": 0.25])
    }

    func testRestoringAboveTheFloorBeatsTheFloor() {
        let result = corrections(before: ["media_player.kitchen": 0.5],
                                 now: ["media_player.kitchen": 0.1, "media_player.home_theater": 0.7],
                                 settings: .init(restore: true, floor: 0.25))
        XCTAssertEqual(result, ["media_player.kitchen": 0.5])
    }

    func testAPinnedSpeakerIsResetToItsPinEitherWay() {
        XCTAssertEqual(corrections(before: [:], now: ["media_player.home_theater": 0.15]),
                       ["media_player.home_theater": 0.7])
        XCTAssertEqual(corrections(before: [:], now: ["media_player.home_theater": 1.0]),
                       ["media_player.home_theater": 0.7], "a line-out pin is exact, not a floor")
        XCTAssertEqual(corrections(before: [:], now: ["media_player.home_theater": 0.71]), [:])
    }

    func testTurningRestoreAndTheFloorOffLeavesOnlyPins() {
        let result = corrections(before: ["media_player.kitchen": 0.5],
                                 now: ["media_player.kitchen": 0.05, "media_player.home_theater": 0.2],
                                 settings: .init(restore: false, floor: 0))
        XCTAssertEqual(result, ["media_player.home_theater": 0.7])
    }

    func testASpeakerThatReportsNoLevelIsLeftAlone() {
        XCTAssertEqual(corrections(before: ["media_player.kitchen": 0.5], now: [:]), [:])
    }

    func testATinyDropIsNotWorthACall() {
        XCTAssertEqual(corrections(before: ["media_player.kitchen": 0.41],
                                   now: ["media_player.kitchen": 0.4, "media_player.home_theater": 0.7]), [:])
    }

    // MARK: - Landing

    func testItHasLandedOnlyWhenPlayingOnTheZone() {
        func account(_ state: String, _ source: String) -> HAEntityState {
            HAEntityState(entityId: "media_player.spotify", state: state, attributes: ["source": .string(source)])
        }
        XCTAssertTrue(StartVolume.hasLanded(on: downstairs, account: account("playing", "Downstairs")))
        XCTAssertFalse(StartVolume.hasLanded(on: downstairs, account: account("paused", "Downstairs")))
        XCTAssertFalse(StartVolume.hasLanded(on: downstairs, account: account("playing", "Kitchen")))
        XCTAssertFalse(StartVolume.hasLanded(on: downstairs, account: nil))
    }

    // MARK: - The guard, end to end

    private func entity(_ id: String, volume: Double) -> HAEntityState {
        HAEntityState(entityId: id, state: "playing", attributes: ["volume_level": .number(volume)])
    }

    private func fastGuard() -> StartVolumeGuard {
        let guardian = StartVolumeGuard()
        guardian.timings = .init(landTimeout: .seconds(2), pollInterval: .milliseconds(10),
                                 settle: .milliseconds(10), recheck: .milliseconds(10))
        guardian.settings = { StartVolumeConfiguration(restore: true, floor: 0.2) }
        return guardian
    }

    func testTheGuardPutsBackWhatTheStartLowered() async {
        let client = MockHAClient()
        client.simulateConnected(entities: [
            entity("media_player.kitchen", volume: 0.5),
            entity("media_player.living_room", volume: 0.35),
            entity("media_player.home_theater", volume: 0.7),
        ])
        let guardian = fastGuard()
        let pending = guardian.prepare(zone: downstairs, zones: zones, accountEntityId: "media_player.spotify", client: client)

        // The handoff: Spotify's one level lands on every member.
        client.simulateConnected(entities: [
            HAEntityState(entityId: "media_player.spotify", state: "playing", attributes: ["source": .string("Downstairs")]),
            entity("media_player.kitchen", volume: 0.15),
            entity("media_player.living_room", volume: 0.15),
            entity("media_player.home_theater", volume: 0.15),
        ])
        guardian.protect(pending, client: client)
        await guardian.waitForCorrections()

        let calls = client.serviceCallLog.filter { $0.method.hasPrefix("setVolume") }
        XCTAssertEqual(Set(calls.map { "\($0.entityId)=\($0.method)" }), [
            "media_player.kitchen=setVolume:0.5",
            "media_player.living_room=setVolume:0.35",
            "media_player.home_theater=setVolume:0.7",
        ])
        XCTAssertEqual(guardian.landed?.zoneId, "media_player.downstairs")
    }

    func testTouchingAVolumeStopsTheGuard() async {
        let client = MockHAClient()
        client.simulateConnected(entities: [entity("media_player.kitchen", volume: 0.5)])
        let guardian = fastGuard()
        guardian.timings.settle = .seconds(5)
        let pending = guardian.prepare(zone: zones[0], zones: zones, accountEntityId: "media_player.spotify", client: client)
        client.simulateConnected(entities: [
            HAEntityState(entityId: "media_player.spotify", state: "playing", attributes: ["source": .string("media_player.kitchen")]),
            entity("media_player.kitchen", volume: 0.1),
        ])
        guardian.protect(pending, client: client)
        guardian.userChangedVolume()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(client.serviceCallLog.contains { $0.method.hasPrefix("setVolume") },
                       "what someone set by hand stands")
    }

    // MARK: - Config

    private let minimalPages = """
    version: 1
    pages:
      - id: home
        title: Home
        system_icon: house.fill
        sections:
          - cards:
              - type: light
                entity: light.example
    """

    func testStartVolumeDefaultsToRestoreAndAFloor() throws {
        let config = try AppConfigurationParser.parse(minimalPages + "\nmedia:\n  accounts: []\n")
        XCTAssertEqual(config.media.startVolume, StartVolumeConfiguration(restore: true, floor: 0.2))
    }

    func testStartVolumeIsRead() throws {
        let config = try AppConfigurationParser.parse(minimalPages + """

        media:
          startVolume: { restore: false, floor: 0.3 }
          accounts: []
        """)
        XCTAssertEqual(config.media.startVolume, StartVolumeConfiguration(restore: false, floor: 0.3))
    }

    func testAFloorOutsideZeroToOneIsRejected() {
        XCTAssertThrowsError(try AppConfigurationParser.parse(minimalPages + """

        media:
          startVolume: { floor: 25 }
          accounts: []
        """)) { error in
            XCTAssertEqual(error as? AppConfigurationError, .invalidStartVolumeFloor(25))
        }
    }
}

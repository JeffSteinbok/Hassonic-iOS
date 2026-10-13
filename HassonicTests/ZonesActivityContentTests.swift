import XCTest
@testable import Hassonic

/// What the speaker Live Activity shows for a given config and HA state.
final class ZonesActivityContentTests: XCTestCase {

    private func speaker(
        _ id: String,
        source: String? = nil,
        enabled: Bool = true,
        defaultVolume: Double? = nil,
        proxy: ProxyDevice? = nil
    ) -> MusicZone {
        MusicZone(entityId: "media_player.\(id)", displayName: id.capitalized, kind: .speaker,
                  sourceName: source, icon: "hifispeaker.fill", memberEntityIds: [],
                  isEnabled: enabled, defaultVolume: defaultVolume, proxy: proxy)
    }

    private func group(_ id: String, source: String?, members: [String], enabled: Bool = true) -> MusicZone {
        MusicZone(entityId: "media_player.\(id)", displayName: id.capitalized, kind: .group,
                  sourceName: source, icon: "house.fill", memberEntityIds: members.map { "media_player.\($0)" },
                  isEnabled: enabled, defaultVolume: nil, proxy: nil)
    }

    private func account(_ zones: [MusicZone]) -> MediaAccount {
        MediaAccount(id: "jamie", displayName: "Jamie", entityId: "media_player.spotify", favorites: [], zones: zones)
    }

    private func entity(_ id: String, state: String = "on", _ attributes: [String: JSONValue] = [:]) -> HAEntityState {
        HAEntityState(entityId: id, state: state, attributes: attributes)
    }

    private let theater = ProxyDevice(entityId: "media_player.avr", inputSource: "ECHO DOT")

    private var household: MediaAccount {
        account([
            speaker("kitchen", source: "Kitchen"),
            speaker("theater", source: "Home Theater", defaultVolume: 0.7, proxy: theater),
            speaker("pinned", source: "Pinned", defaultVolume: 0.5),
            speaker("hallway"),
            speaker("retired", source: "Retired", enabled: false),
            group("downstairs", source: "Downstairs", members: ["kitchen", "theater", "pinned"]),
            group("everywhere", source: "Everywhere", members: ["kitchen", "hallway"]),
            group("old", source: "Old", members: ["kitchen"], enabled: false),
        ])
    }

    // MARK: - Which zones appear

    func testZonesAreCastableEnabledOnesWithGroupsFirst() {
        let ids = ZonesActivityContent.zones(for: household).map(\.id)
        XCTAssertEqual(ids, [
            "media_player.downstairs", "media_player.everywhere",
            "media_player.kitchen", "media_player.theater", "media_player.pinned",
        ])
    }

    func testQuickZonesSkipUnavailableAndCapAtFour() {
        let quick = ZonesActivityContent.quickZones(for: household) { $0 != "media_player.everywhere" }
        XCTAssertEqual(quick.map(\.id), [
            "media_player.downstairs", "media_player.kitchen", "media_player.theater", "media_player.pinned",
        ])
        XCTAssertEqual(ZonesActivityContent.maxQuickZones, 4)
    }

    func testConfiguredQuickZonesKeepTheirOrderAndSkipUnavailableWithoutBackfill() {
        var account = household
        account.liveActivityZoneIds = ["media_player.pinned", "media_player.kitchen", "media_player.everywhere"]

        let quick = ZonesActivityContent.quickZones(for: account) { $0 != "media_player.kitchen" }

        XCTAssertEqual(quick.map(\.id), ["media_player.pinned", "media_player.everywhere"])
    }

    // MARK: - Volume targets

    func testSpeakerVolumeUsesItsProxy() {
        let zones = ZonesActivityContent.zones(for: household)
        XCTAssertEqual(zones.first { $0.id == "media_player.theater" }?.volumeEntityIds, ["media_player.avr"])
    }

    func testPinnedSpeakerWithoutProxyIsNotAdjustable() {
        let zones = ZonesActivityContent.zones(for: household)
        XCTAssertEqual(zones.first { $0.id == "media_player.pinned" }?.volumeEntityIds, [])
    }

    func testGroupVolumeTargetsEachMemberProxyAware() {
        let zones = ZonesActivityContent.zones(for: household)
        XCTAssertEqual(zones.first { $0.id == "media_player.downstairs" }?.volumeEntityIds,
                       ["media_player.kitchen", "media_player.avr"])
        // A member that isn't castable on its own is still a speaker in the group.
        XCTAssertEqual(zones.first { $0.id == "media_player.everywhere" }?.volumeEntityIds,
                       ["media_player.kitchen", "media_player.hallway"])
    }

    // MARK: - Content state

    func testActiveZoneMatchesSourceIgnoringCaseAndWhitespace() {
        let zones = ZonesActivityContent.zones(for: household)
        let spotify = entity("media_player.spotify", state: "playing", ["source": .string(" downstairs ")])
        let entities: [String: HAEntityState] = [
            "media_player.kitchen": entity("media_player.kitchen", ["volume_level": .number(0.4)]),
            "media_player.avr": entity("media_player.avr", ["volume_level": .number(0.6)]),
        ]

        let state = ZonesActivityContent.state(accountEntity: spotify, zones: zones) { entities[$0] }

        XCTAssertEqual(state.activeZone?.id, "media_player.downstairs")
        XCTAssertEqual(state.volume ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertTrue(state.isPlaying)
        XCTAssertNil(state.pendingZoneId)
        XCTAssertNil(state.message)
    }

    func testUnknownSourceHasNoActiveZoneOrVolume() {
        let spotify = entity("media_player.spotify", state: "paused", ["source": .string("Someone's Phone")])
        let state = ZonesActivityContent.state(accountEntity: spotify, zones: ZonesActivityContent.zones(for: household)) { _ in nil }
        XCTAssertNil(state.activeZone)
        XCTAssertNil(state.volume)
        XCTAssertFalse(state.isPlaying)
    }

    func testVolumeIsNilWhenNoTargetReportsALevel() {
        let zones = ZonesActivityContent.zones(for: household)
        let spotify = entity("media_player.spotify", state: "playing", ["source": .string("Kitchen")])
        let state = ZonesActivityContent.state(accountEntity: spotify, zones: zones) { self.entity($0) }
        XCTAssertEqual(state.activeZone?.id, "media_player.kitchen")
        XCTAssertNil(state.volume)
    }

    func testHasMediaFollowsNowPlayingRule() {
        XCTAssertFalse(ZonesActivityContent.hasMedia(nil))
        XCTAssertFalse(ZonesActivityContent.hasMedia(entity("media_player.spotify", state: "idle")))
        XCTAssertTrue(ZonesActivityContent.hasMedia(entity("media_player.spotify", state: "paused", ["media_title": .string("Song")])))
    }

    // MARK: - Setting volume

    private let trio = ZonesActivityAttributes.Zone(id: "g", name: "G", icon: "", sourceName: "G",
                                                   volumeEntityIds: ["a", "b", "c"])

    func testSettingVolumeShiftsEverySpeakerAndKeepsTheBalance() {
        let entities: [String: HAEntityState] = [
            "a": entity("a", ["volume_level": .number(0.2)]),
            "b": entity("b", ["volume_level": .number(0.4)]),
            "c": entity("c"),
        ]

        let set = ZonesActivityContent.volumes(of: trio, settingTo: 0.6) { entities[$0] }

        // Average 0.3 → 0.6: both move up 0.3; c reports nothing and is left alone.
        XCTAssertEqual(set.map(\.entityId), ["a", "b"])
        XCTAssertEqual(set.map(\.level), [0.5, 0.7])
    }

    func testSettingVolumeClampsAtTheEnds() {
        let entities: [String: HAEntityState] = [
            "a": entity("a", ["volume_level": .number(0.9)]),
            "b": entity("b", ["volume_level": .number(0.5)]),
        ]
        XCTAssertEqual(ZonesActivityContent.volumes(of: trio, settingTo: 1.0) { entities[$0] }.map(\.level), [1.0, 0.8])
        XCTAssertEqual(ZonesActivityContent.volumes(of: trio, settingTo: 0.1) { entities[$0] }.map(\.level), [0.3, 0.0])
    }

    /// Idle Echos often report no level at all; a tap should still do something.
    func testWhenNoSpeakerReportsALevelAllGoStraightToIt() {
        let set = ZonesActivityContent.volumes(of: trio, settingTo: 0.3) { _ in nil }
        XCTAssertEqual(set.map(\.entityId), ["a", "b", "c"])
        XCTAssertEqual(set.map(\.level), [0.3, 0.3, 0.3])
    }

    // MARK: - App mark

    func testAppMarkFollowsTheAlternateIcon() {
        XCTAssertNil(ZonesActivityAttributes.appMark(forAlternateIcon: nil))
        XCTAssertEqual(ZonesActivityAttributes.appMark(forAlternateIcon: "AppIcon-Clay-Coral"), "AppMark-Clay-Coral")
        XCTAssertNil(ZonesActivityAttributes.appMark(forAlternateIcon: "Something"))
    }

    func testEveryAlternateIconHasAWidgetMark() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let appAssets = root.appendingPathComponent("Hassonic/Assets.xcassets")
        let widgetAssets = root.appendingPathComponent("HassonicWidgets/Assets.xcassets")
        let icons = try FileManager.default.contentsOfDirectory(atPath: appAssets.path)
            .filter { $0.hasPrefix("AppIcon-") && $0.hasSuffix(".appiconset") }
        XCTAssertFalse(icons.isEmpty)
        for icon in icons {
            let mark = try XCTUnwrap(ZonesActivityAttributes.appMark(forAlternateIcon: String(icon.dropLast(".appiconset".count))))
            XCTAssertTrue(FileManager.default.fileExists(atPath: widgetAssets.appendingPathComponent("\(mark).imageset").path), "\(icon) has no \(mark)")
        }
    }

    func testContentStateFromBeforeAppMarkStillDecodes() throws {
        let json = #"{"isPlaying":true}"#.data(using: .utf8)!
        let state = try JSONDecoder().decode(ZonesActivityAttributes.ContentState.self, from: json)
        XCTAssertNil(state.appMark)
    }
}

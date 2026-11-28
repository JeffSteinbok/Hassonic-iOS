import XCTest
@testable import Hassonic

/// The Music tab's two layouts: which one the state asks for, holding still
/// under a finger, what else is playing, and which speaker the start layout
/// offers first.
final class MusicTabLayoutTests: XCTestCase {
    private func zone(_ id: String, source: String? = nil, kind: MusicZone.Kind = .speaker,
                      members: [String] = [], enabled: Bool = true) -> MusicZone {
        MusicZone(entityId: id, displayName: id, kind: kind, sourceName: source ?? id, icon: "hifispeaker.fill",
                  memberEntityIds: members, isEnabled: enabled, defaultVolume: nil, proxy: nil)
    }

    private lazy var kitchen = zone("kitchen", source: "Kitchen")
    private lazy var living = zone("living", source: "Living Room")
    private lazy var office = zone("office", source: "Office")
    private lazy var patio = zone("patio", source: "Patio")
    private lazy var downstairs = zone("downstairs", source: "Downstairs", kind: .group, members: ["kitchen", "living"])
    private lazy var zones = [kitchen, living, office, patio, downstairs]

    // MARK: - Wanted layout

    func testPlayingOrPausedWantsThePlayingLayout() {
        XCTAssertEqual(MusicTabLayout.wanted(hasMedia: true), .playing)
        XCTAssertEqual(MusicTabLayout.wanted(hasMedia: false), .start)
    }

    // MARK: - Latch

    func testChangesLandAtOnceWhenNobodyIsTouching() {
        var latch = MusicTabModeLatch(.start)
        XCTAssertTrue(latch.want(.playing))
        XCTAssertEqual(latch.shown, .playing)
        XCTAssertFalse(latch.want(.playing), "asking again changes nothing")
    }

    func testAStartWaitsForTheFingerToLift() {
        var latch = MusicTabModeLatch(.start)
        latch.hold(true)
        XCTAssertFalse(latch.want(.playing))
        XCTAssertEqual(latch.shown, .start, "nothing moves under the finger")
        XCTAssertTrue(latch.hold(false))
        XCTAssertEqual(latch.shown, .playing)
    }

    func testAStopAndRestartWhileTouchingLeavesTheLayoutAlone() {
        var latch = MusicTabModeLatch(.playing)
        latch.hold(true)
        latch.want(.start)
        latch.want(.playing)
        XCTAssertFalse(latch.hold(false))
        XCTAssertEqual(latch.shown, .playing)
        XCTAssertNil(latch.pending)
    }

    func testOnlyTheLatestWishLands() {
        var latch = MusicTabModeLatch(.start)
        latch.hold(true)
        latch.want(.playing)
        latch.want(.start)
        XCTAssertFalse(latch.hold(false))
        XCTAssertEqual(latch.shown, .start)
    }

    // MARK: - Other zones playing

    private func others(active: MusicZone?, playing: Set<String>) -> [String] {
        MusicTabLayout.otherPlaying(zones: zones, active: active) { playing.contains($0) }.map(\.entityId)
    }

    func testNothingElsePlaying() {
        XCTAssertEqual(others(active: kitchen, playing: ["kitchen"]), [])
    }

    func testASpeakerPlayingOnItsOwnIsListed() {
        XCTAssertEqual(others(active: kitchen, playing: ["kitchen", "office"]), ["office"])
    }

    func testTheActiveGroupsMembersArentListed() {
        XCTAssertEqual(others(active: downstairs, playing: ["downstairs", "kitchen", "living", "patio"]), ["patio"])
    }

    func testAPlayingGroupStandsForItsMembers() {
        XCTAssertEqual(others(active: office, playing: ["office", "downstairs", "kitchen", "living"]), ["downstairs"])
    }

    func testAGroupSharingASpeakerWithTheActiveZoneIsLeftOut() {
        // Kitchen is playing the account; the group reports playing because
        // its member is.
        XCTAssertEqual(others(active: kitchen, playing: ["kitchen", "downstairs", "living"]), ["living"])
    }

    func testWithNothingOnTheAccountEveryPlayingZoneIsElsewhere() {
        XCTAssertEqual(others(active: nil, playing: ["kitchen", "patio"]), ["kitchen", "patio"])
    }

    func testDisabledZonesArentListed() {
        let hidden = zone("garage", enabled: false)
        let listed = MusicTabLayout.otherPlaying(zones: [kitchen, hidden], active: nil) { _ in true }
        XCTAssertEqual(listed.map(\.entityId), ["kitchen"])
    }

    // MARK: - Default speaker

    func testThePickedSpeakerComesFirst() {
        let target = MusicTabLayout.defaultTarget(zones: zones, picked: "office", rememberedSource: "Kitchen")
        XCTAssertEqual(target?.id, "office")
    }

    func testThenWhereTheAccountLastPlayed() {
        let target = MusicTabLayout.defaultTarget(zones: zones, picked: nil, rememberedSource: " living room ")
        XCTAssertEqual(target?.id, "living")
    }

    func testAPickThatNoLongerExistsFallsBack() {
        let target = MusicTabLayout.defaultTarget(zones: zones, picked: "gone", rememberedSource: "Patio")
        XCTAssertEqual(target?.id, "patio")
    }

    func testNothingToGoOnAsks() {
        XCTAssertNil(MusicTabLayout.defaultTarget(zones: zones, picked: nil, rememberedSource: nil))
        XCTAssertNil(MusicTabLayout.defaultTarget(zones: zones, picked: nil, rememberedSource: ""))
    }
}

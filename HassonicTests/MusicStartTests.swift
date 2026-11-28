import XCTest
@testable import Hassonic

/// Starting music from Favorites, Recents, Browse and a room: where it plays,
/// when the Play On sheet asks, and what happens when it doesn't start.
@MainActor
final class MusicStartTests: XCTestCase {
    private let account = "media_player.spotify_alex"
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "MusicStartTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func zone(_ id: String, source: String?, kind: MusicZone.Kind = .speaker, enabled: Bool = true) -> MusicZone {
        MusicZone(entityId: id, displayName: source ?? id, kind: kind, sourceName: source, icon: "hifispeaker.fill",
                  memberEntityIds: [], isEnabled: enabled, defaultVolume: nil, proxy: nil)
    }

    private lazy var kitchen = zone("media_player.kitchen", source: "Kitchen")
    private lazy var office = zone("media_player.office", source: "Office")

    private func context(hasMedia: Bool, target: MusicZone? = nil) -> MusicStartContext {
        MusicStartContext(accountEntityId: account, accountDisplayName: "Alex", speakerClaim: nil,
                          zones: [kitchen, office], hasMedia: hasMedia, target: target)
    }

    private func player(_ state: String, source: String? = nil) -> HAEntityState {
        var attributes: [String: JSONValue] = [:]
        if let source { attributes["source"] = .string(source) }
        return HAEntityState(entityId: account, state: state, attributes: attributes)
    }

    private let request = MusicStartRequest(
        contentType: "playlist", contentId: "spotify:playlist:1", displayName: "Morning Coffee",
        recent: RecentMusicItem(contentType: "playlist", contentId: "spotify:playlist:1", title: "Morning Coffee"))

    private func makeStarter() -> (MusicStarter, RecentMusicStore) {
        let recents = RecentMusicStore(defaults: defaults)
        let starter = MusicStarter(defaults: defaults, recents: recents)
        starter.startTimeout = .milliseconds(600)
        return (starter, recents)
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting", file: file, line: line)
    }

    private func calls(_ client: MockHAClient, _ prefix: String) -> Int {
        client.serviceCallLog.filter { $0.method.hasPrefix(prefix) }.count
    }

    // MARK: - Routing

    func testNothingPlayingAsksWhere() {
        XCTAssertEqual(MusicStart.route(target: nil, hasMedia: false, currentSource: nil, rememberedSource: "Kitchen"), .ask,
                       "A remembered speaker from an earlier session isn't somewhere to play now")
    }

    func testPlayingSomewherePlaysThere() {
        XCTAssertEqual(MusicStart.route(target: nil, hasMedia: true, currentSource: "Kitchen", rememberedSource: nil), .playHere)
        XCTAssertEqual(MusicStart.route(target: nil, hasMedia: true, currentSource: nil, rememberedSource: "Kitchen"), .playHere,
                       "Home Assistant leaves out `source` while paused")
        XCTAssertEqual(MusicStart.route(target: nil, hasMedia: true, currentSource: nil, rememberedSource: nil), .ask)
    }

    func testRoomSpeakerAlreadyPlayingPlaysThere() {
        XCTAssertEqual(MusicStart.route(target: kitchen, hasMedia: true, currentSource: "kitchen", rememberedSource: nil), .playHere)
    }

    func testRoomSpeakerElsewhereSwitchesWithoutAsking() {
        XCTAssertEqual(MusicStart.route(target: kitchen, hasMedia: true, currentSource: "Office", rememberedSource: nil),
                       .switchTo(zoneId: kitchen.id))
        XCTAssertEqual(MusicStart.route(target: kitchen, hasMedia: false, currentSource: "Kitchen", rememberedSource: nil),
                       .switchTo(zoneId: kitchen.id), "Idle: the speaker may have dropped off the account")
    }

    // MARK: - Reading the answer

    func testNoActiveDeviceIsASpeakerProblem() {
        for message in ["No active device found", "Player command failed: No active device found", "No active playback device"] {
            XCTAssertEqual(MusicStart.outcome(ofFailure: HAResultError(code: nil, message: message)), .noSpeaker, message)
        }
    }

    func testOtherFailuresKeepTheirMessage() {
        XCTAssertEqual(MusicStart.outcome(ofFailure: HAResultError(code: nil, message: "Spotify Premium required")),
                       .failed("Spotify Premium required"))
        XCTAssertEqual(MusicStart.outcome(ofFailure: nil), .failed("Home Assistant couldn't start it."))
    }

    func testStartedOnlyOncePlaying() {
        XCTAssertTrue(MusicStart.hasStarted(before: player("playing"), now: player("playing")), "It already had a speaker")
        XCTAssertTrue(MusicStart.hasStarted(before: player("idle"), now: player("playing")))
        XCTAssertFalse(MusicStart.hasStarted(before: player("idle"), now: player("idle")))
        XCTAssertFalse(MusicStart.hasStarted(before: nil, now: player("paused")))
    }

    // MARK: - The starter

    func testAskingShowsThePlayOnSheetAndDoesNotPlay() {
        let (starter, _) = makeStarter()
        let client = MockHAClient()
        starter.start(request, context: context(hasMedia: false), client: client)

        XCTAssertEqual(starter.playOn?.request, request)
        XCTAssertNil(starter.playOn?.autoZone)
        XCTAssertEqual(calls(client, "playMedia"), 0)
    }

    func testSecondTapWhileTheSheetIsUpIsIgnored() {
        let (starter, _) = makeStarter()
        let client = MockHAClient()
        starter.start(request, context: context(hasMedia: false), client: client)
        let other = MusicStartRequest(contentType: "album", contentId: "spotify:album:2", displayName: "Long Light")
        starter.start(other, context: context(hasMedia: false), client: client)

        XCTAssertEqual(starter.playOn?.request.contentId, request.contentId)
    }

    func testCancellingTheSheetPlaysNothing() async {
        let (starter, recents) = makeStarter()
        let client = MockHAClient()
        starter.start(request, context: context(hasMedia: false), client: client)
        starter.sheetDismissed(picked: false, switched: false, client: client)

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(calls(client, "playMedia"), 0)
        XCTAssertTrue(recents.items(for: account).isEmpty)
        XCTAssertNil(starter.playOn)
    }

    func testPickedSpeakerPlaysAndLandsInRecents() async {
        let (starter, recents) = makeStarter()
        let client = MockHAClient()
        client.simulateConnected(entities: [player("idle")])
        client.stateAfterPlay = player("playing", source: "Kitchen")
        var started = false
        starter.start(request, context: context(hasMedia: false), client: client) { started = true }
        starter.sheetDismissed(picked: true, switched: false, client: client)

        await eventually { started }
        XCTAssertEqual(calls(client, "playMediaChecked"), 1)
        XCTAssertEqual(recents.items(for: account).first?.contentId, request.contentId)
        XCTAssertNil(starter.failure)
    }

    func testAfterAnAccountSwitchItResendsRatherThanChecks() async {
        let (starter, _) = makeStarter()
        let client = MockHAClient()
        var started = false
        starter.start(request, context: context(hasMedia: false), client: client) { started = true }
        starter.sheetDismissed(picked: true, switched: true, client: client)

        XCTAssertTrue(started)
        await eventually { calls(client, "playMedia:") == 1 }
        XCTAssertEqual(calls(client, "playMediaChecked"), 0)
    }

    func testPlayingDirectlyWhenSomethingIsPlaying() async {
        let (starter, _) = makeStarter()
        let client = MockHAClient()
        client.simulateConnected(entities: [player("playing", source: "Kitchen")])
        var started = false
        starter.start(request, context: context(hasMedia: true), client: client) { started = true }

        XCTAssertNil(starter.playOn, "Already playing somewhere: no need to ask")
        await eventually { started }
    }

    func testNoActiveDeviceFallsBackToThePlayOnSheet() async {
        let (starter, _) = makeStarter()
        let client = MockHAClient()
        client.simulateConnected(entities: [player("paused", source: "Kitchen")])
        client.playMediaResult = HAServiceCallResult(success: false, error: HAResultError(code: nil, message: "No active device found"))
        starter.start(request, context: context(hasMedia: true), client: client)

        await eventually { starter.playOn != nil }
        XCTAssertEqual(starter.playOn?.notice, MusicStart.noSpeakerNotice(for: "Morning Coffee"))
        XCTAssertNil(starter.failure)
    }

    func testSilentNoOpFallsBackToThePlayOnSheet() async {
        // The call succeeds but nothing starts: the provider dropped it.
        let (starter, _) = makeStarter()
        let client = MockHAClient()
        client.simulateConnected(entities: [player("paused", source: "Kitchen")])
        starter.start(request, context: context(hasMedia: true), client: client)

        await eventually { starter.playOn != nil }
        XCTAssertNotNil(starter.playOn?.notice)
    }

    func testFailureAfterPickingSaysWhy() async {
        let (starter, recents) = makeStarter()
        let client = MockHAClient()
        client.simulateConnected(entities: [player("idle")])
        client.playMediaResult = HAServiceCallResult(success: false, error: HAResultError(code: nil, message: "Spotify Premium required"))
        starter.start(request, context: context(hasMedia: false), client: client)
        starter.sheetDismissed(picked: true, switched: false, client: client)

        await eventually { starter.failure != nil }
        XCTAssertEqual(starter.failure?.message, "Spotify Premium required")
        XCTAssertNotNil(starter.failure?.retry, "Offers to choose another speaker")
        XCTAssertNil(starter.playOn, "Doesn't loop back into the sheet on its own")
        XCTAssertTrue(recents.items(for: account).isEmpty, "Only what started goes in Recents")

        starter.chooseSpeaker(for: starter.failure!)
        XCTAssertNil(starter.failure)
        XCTAssertEqual(starter.playOn?.request, request)
    }

    func testRoomSpeakerSwitchesStraightAway() {
        let (starter, _) = makeStarter()
        let client = MockHAClient()
        client.simulateConnected(entities: [player("playing", source: "Office")])
        starter.start(request, context: context(hasMedia: true, target: kitchen), client: client)

        XCTAssertEqual(starter.playOn?.autoZone?.id, kitchen.id)
    }

    func testRoomSpeakerFailureDoesNotOfferAnotherSpeaker() async {
        let (starter, _) = makeStarter()
        let client = MockHAClient()
        client.simulateConnected(entities: [player("playing", source: "Kitchen")])
        client.playMediaResult = HAServiceCallResult(success: false, error: HAResultError(code: nil, message: "No active device found"))
        starter.start(request, context: context(hasMedia: true, target: kitchen), client: client)

        await eventually { starter.failure != nil }
        XCTAssertNil(starter.playOn, "The room's speaker was the point")
        XCTAssertNil(starter.failure?.retry)
    }

    // MARK: - A room's speaker

    private func account(_ id: String, zones: [MusicZone]) -> MediaAccount {
        MediaAccount(id: id, displayName: id, entityId: "media_player.spotify_\(id)", favorites: [], zones: zones)
    }

    func testRoomUsesTheSelectedAccountsSpeaker() {
        let accounts = [account("alex", zones: [kitchen]), account("sam", zones: [kitchen])]
        let target = RoomMusic.target(roomEntities: ["light.lamp", "media_player.kitchen"], accounts: accounts, selectedAccountId: "sam")
        XCTAssertEqual(target?.account.id, "sam")
        XCTAssertEqual(target?.zone.id, kitchen.id)
    }

    func testRoomFallsBackToAnAccountWithTheSpeaker() {
        let accounts = [account("alex", zones: [office]), account("sam", zones: [kitchen])]
        let target = RoomMusic.target(roomEntities: ["media_player.kitchen"], accounts: accounts, selectedAccountId: "alex")
        XCTAssertEqual(target?.account.id, "sam")
    }

    func testRoomSkipsSpeakersThatCantCast() {
        let accounts = [account("alex", zones: [zone("media_player.kitchen", source: nil),
                                                zone("media_player.tv", source: "TV", enabled: false)])]
        XCTAssertNil(RoomMusic.target(roomEntities: ["media_player.kitchen", "media_player.tv"], accounts: accounts, selectedAccountId: nil))
    }

    func testRoomPrefersASpeakerToAGroup() {
        let group = zone("media_player.downstairs", source: "Downstairs", kind: .group)
        let accounts = [account("alex", zones: [group, kitchen])]
        let target = RoomMusic.target(roomEntities: ["media_player.downstairs", "media_player.kitchen"], accounts: accounts, selectedAccountId: nil)
        XCTAssertEqual(target?.zone.id, kitchen.id)
    }

    // MARK: - Requests

    private func node(_ json: String) throws -> HABrowseMediaNode {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(HABrowseMediaNode.self, from: Data(json.utf8))
    }

    func testBrowseFoldersAreNotPlayable() throws {
        let folder = try node("""
        {"title": "Playlists", "media_class": "directory", "media_content_type": "spotify://current_user_playlists",
         "media_content_id": "spotify://current_user_playlists", "can_play": false, "can_expand": true}
        """)
        XCTAssertNil(MusicStartRequest(node: folder))
    }

    func testBrowsePickCarriesItsRecent() throws {
        let album = try node("""
        {"title": "Long Light", "media_class": "album", "media_content_type": "spotify://album",
         "media_content_id": "spotify:album:9", "can_play": true, "can_expand": true, "thumbnail": "https://i.scdn.co/x"}
        """)
        let request = try XCTUnwrap(MusicStartRequest(node: album))
        XCTAssertEqual(request.displayName, "Long Light")
        XCTAssertEqual(request.recent?.thumbnail, "https://i.scdn.co/x")
    }
}

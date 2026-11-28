import XCTest
@testable import Hassonic

/// The `tv_remote` card: its config, and what each panel's keys send.
@MainActor
final class TVRemoteTests: XCTestCase {

    private let tvRemote = "remote.family_room_samsung_tv"
    private let tvPlayer = "media_player.family_room_samsung_tv"
    private let boxRemote = "remote.xfinity"

    private func card(_ yaml: String) throws -> DashboardTVRemoteConfiguration {
        let config = try AppConfigurationParser.parse("""
        version: 1
        pages:
          - id: remote
            title: Remote
            system_icon: tv
            sections:
              - cards:
                  - type: tv_remote
        \(yaml)
        """)
        guard case .tvRemote(let remote) = config.pages[0].sections[0].cards[0] else {
            XCTFail("expected a tv_remote card")
            throw CancellationError()
        }
        return remote
    }

    private func familyRoom() throws -> DashboardTVRemoteConfiguration {
        try card("""
                    title: Family Room
                    tv:
                      kind: samsung
                      remote: remote.family_room_samsung_tv
                      mediaPlayer: media_player.family_room_samsung_tv
                    box:
                      kind: xfinity
                      remote: remote.xfinity
        """)
    }

    private func error(_ yaml: String) -> DashboardConfigurationError? {
        var caught: DashboardConfigurationError?
        XCTAssertThrowsError(try card(yaml)) { caught = $0 as? DashboardConfigurationError }
        return caught
    }

    private func sent(_ actions: [TVRemoteAction]) -> [String] {
        let client = MockHAClient()
        DashboardCardActionRouter.perform(actions, client: client)
        return client.serviceCallLog.map { "\($0.entityId) \($0.method)" }
    }

    // MARK: Config

    func testCardIsParsed() throws {
        let remote = try familyRoom()
        XCTAssertEqual(remote.title, "Family Room")
        XCTAssertEqual(remote.tv?.kind, .samsung)
        XCTAssertEqual(remote.tv?.mediaPlayer, tvPlayer)
        XCTAssertEqual(remote.tv?.displayName, "Samsung TV")
        XCTAssertEqual(remote.box?.kind, .xfinity)
        XCTAssertEqual(remote.box?.displayName, "Xfinity")
    }

    func testANameRelabelsThePanel() throws {
        let remote = try card("""
                    box: { kind: xfinity, remote: remote.xfinity, name: Comcast }
        """)
        XCTAssertEqual(remote.box?.displayName, "Comcast")
        XCTAssertNil(remote.tv)
    }

    func testOldRoutingKeysAreIgnored() throws {
        // Configs from the single-remote version still load.
        let remote = try card("""
                    tv: { kind: samsung, remote: remote.tv }
                    box: { kind: xfinity, remote: remote.xfinity, source: TV/HDMI }
                    keys: { volume: tv }
        """)
        XCTAssertNotNil(remote.box)
    }

    func testANoDeviceCardIsRejected() {
        XCTAssertEqual(error("""
                    title: Nothing
        """), .tvRemoteNeedsADevice(cardType: "tv_remote"))
    }

    func testLockScreenKeysLoad() throws {
        let remote = try card("""
                    tv: { kind: samsung, remote: remote.tv }
                    box: { kind: xfinity, remote: remote.xfinity }
                    lockScreen: [open, tv.playPause, box.playPause]
        """)
        XCTAssertEqual(remote.lockScreen?.compactMap(DashboardTVRemoteConfiguration.LockScreenKey.init),
                       [.open, .key(.playPause, .tv), .key(.playPause, .box)])
    }

    func testALockScreenKeyForAMissingDeviceIsRejected() {
        XCTAssertEqual(error("""
                    tv: { kind: samsung, remote: remote.tv }
                    lockScreen: [box.playPause]
        """), .unknownLockScreenKey("box.playPause", cardType: "tv_remote"))
    }

    func testAMisspelledLockScreenKeyIsRejected() {
        XCTAssertEqual(error("""
                    tv: { kind: samsung, remote: remote.tv }
                    lockScreen: [tv.play_pause]
        """), .unknownLockScreenKey("tv.play_pause", cardType: "tv_remote"))
    }

    func testWrongDomainsAreRejected() {
        XCTAssertEqual(error("""
                    tv: { kind: samsung, remote: media_player.tv }
        """), .invalidEntity(entityID: "media_player.tv", cardType: "tv_remote", expectedDomain: "remote"))
    }

    func testAnUnknownKindIsRejected() {
        XCTAssertThrowsError(try card("""
                    tv: { kind: sony, remote: remote.tv }
        """))
    }

    // MARK: Samsung panel

    func testTVPanelKeysGoToTheSamsung() throws {
        let remote = try familyRoom()
        let keys: [TVRemoteKey] = [.power, .volumeUp, .volumeDown, .mute, .up, .ok, .home, .back]
        XCTAssertEqual(sent(keys.flatMap { remote.actions(for: $0, on: .tv) }), [
            "\(tvRemote) remoteSendCommand:KEY_POWER",
            "\(tvRemote) remoteSendCommand:KEY_VOLUP",
            "\(tvRemote) remoteSendCommand:KEY_VOLDOWN",
            "\(tvRemote) remoteSendCommand:KEY_MUTE",
            "\(tvRemote) remoteSendCommand:KEY_UP",
            "\(tvRemote) remoteSendCommand:KEY_ENTER",
            "\(tvRemote) remoteSendCommand:KEY_HOME",
            "\(tvRemote) remoteSendCommand:KEY_RETURN",
        ])
    }

    func testSamsungPlayPauseUsesTheMediaPlayer() throws {
        let remote = try familyRoom()
        XCTAssertEqual(remote.actions(for: .playPause, on: .tv), [.mediaPlayPause(mediaPlayer: tvPlayer)])
    }

    func testSamsungPlayPauseAlternatesWithoutAMediaPlayer() throws {
        let remote = try card("""
                    tv: { kind: samsung, remote: remote.tv }
        """)
        let actions = remote.actions(for: .playPause, on: .tv)
        XCTAssertEqual(actions, [.samsungPlayPause(remote: "remote.tv")])
        let client = MockHAClient()
        DashboardCardActionRouter.perform(actions, client: client)
        DashboardCardActionRouter.perform(actions, client: client)
        XCTAssertEqual(client.serviceCallLog.map(\.method), ["remoteSendCommand:KEY_PAUSE", "remoteSendCommand:KEY_PLAY"])
    }

    func testSamsungNumberPad() throws {
        let remote = try familyRoom()
        XCTAssertEqual(remote.digitActions(7, on: .tv), [.send(remote: tvRemote, command: "KEY_7")])
        XCTAssertEqual(remote.actions(for: .lastChannel, on: .tv), [.send(remote: tvRemote, command: "KEY_PRECH")])
        XCTAssertEqual(remote.actions(for: .enter, on: .tv), [.send(remote: tvRemote, command: "KEY_ENTER")])
    }

    func testAPowerScriptReplacesThePowerKey() throws {
        let remote = try card("""
                    tv: { kind: samsung, remote: remote.tv, power: script.tv_power }
        """)
        XCTAssertEqual(sent(remote.actions(for: .power, on: .tv)), ["script.tv_power runScript"])
        XCTAssertEqual(remote.actions(for: .mute, on: .tv), [.send(remote: "remote.tv", command: "KEY_MUTE")])
    }

    func testAPowerThatIsntAScriptIsRejected() {
        XCTAssertEqual(error("""
                    tv: { kind: samsung, remote: remote.tv, power: remote.tv }
        """), .invalidEntity(entityID: "remote.tv", cardType: "tv_remote", expectedDomain: "script"))
    }

    // MARK: Xfinity panel

    func testBoxPanelKeysGoToTheXfinity() throws {
        let remote = try familyRoom()
        let keys: [TVRemoteKey] = [.pageUp, .pageDown, .channelUp, .left, .ok, .keyA, .keyD, .back, .exit, .guide, .info, .menu, .rewind, .playPause, .fastForward, .record]
        XCTAssertEqual(sent(keys.flatMap { remote.actions(for: $0, on: .box) }).map { $0.replacingOccurrences(of: "\(boxRemote) remoteSendCommand:", with: "") }, [
            "page_up", "page_down", "channel_up", "left", "ok", "key_a", "key_d",
            "last", "exit", "guide", "info", "menu", "rewind", "play_pause", "fast_forward", "record",
        ])
    }

    func testXfinityNumberPad() throws {
        let remote = try familyRoom()
        XCTAssertEqual(remote.digitActions(0, on: .box), [.send(remote: boxRemote, command: "number_0")])
        XCTAssertEqual(remote.actions(for: .lastChannel, on: .box), [.send(remote: boxRemote, command: "last")])
        XCTAssertEqual(remote.actions(for: .enter, on: .box), [.send(remote: boxRemote, command: "ok")])
        XCTAssertEqual(remote.digitActions(10, on: .box), [])
    }

    func testEveryKeyHasACommandOnXfinity() {
        for key in TVRemoteKey.allCases {
            XCTAssertNotNil(key.command(on: .xfinity), "\(key)")
        }
    }

    func testSamsungHasNoPageKeys() {
        XCTAssertNil(TVRemoteKey.pageUp.command(on: .samsung))
        XCTAssertNil(TVRemoteKey.pageDown.command(on: .samsung))
    }

    func testAMissingDeviceSendsNothing() throws {
        let remote = try card("""
                    tv: { kind: samsung, remote: remote.tv }
        """)
        XCTAssertEqual(remote.actions(for: .guide, on: .box), [])
        XCTAssertEqual(remote.digitActions(1, on: .box), [])
    }

    // MARK: Voice

    func testAnXfinityBoxTakesWhatYouSayAsText() throws {
        let remote = try familyRoom()
        XCTAssertTrue(remote.boxTakesVoice)
        XCTAssertEqual(remote.voiceActions("  watch ESPN "), [.sendText(remote: "remote.xfinity", text: "watch ESPN")])
        XCTAssertEqual(remote.voiceActions("   "), [])
    }

    func testSavedVoiceCommandsComeFromTheBox() throws {
        let remote = try card("""
                    box:
                      kind: xfinity
                      remote: remote.xfinity
                      favorites:
                        - { name: ESPN, say: "watch ESPN", icon: sportscourt.fill }
                        - { name: Kids, say: "show me kids movies" }
                        - { name: Blank, say: "" }
        """)
        XCTAssertEqual(remote.voiceFavorites.map(\.name), ["ESPN", "Kids"])
        XCTAssertEqual(remote.voiceFavorites.first?.icon, "sportscourt.fill")
        XCTAssertEqual(remote.voiceActions(remote.voiceFavorites[1].say), [.sendText(remote: "remote.xfinity", text: "show me kids movies")])
    }

    func testOnlyAnXfinityBoxOffersSavedCommands() throws {
        let remote = try card("""
                    box: { kind: samsung, remote: remote.tv, favorites: [{ name: ESPN, say: "watch ESPN" }] }
        """)
        XCTAssertEqual(remote.voiceFavorites, [])
    }

    func testNoBoxMeansNoVoice() throws {
        let remote = try card("""
                    tv: { kind: samsung, remote: remote.tv }
        """)
        XCTAssertFalse(remote.boxTakesVoice)
        XCTAssertEqual(remote.voiceActions("watch ESPN"), [])
    }

    func testAVoiceCommandReachesTheIntegration() throws {
        let mock = MockHAClient()
        DashboardCardActionRouter.perform(try familyRoom().voiceActions("watch ESPN"), client: mock)
        XCTAssertEqual(mock.serviceCallLog.map(\.method), ["remoteSendText:watch ESPN"])
        XCTAssertEqual(mock.serviceCallLog.map(\.entityId), ["remote.xfinity"])
    }

    // MARK: The TV's power

    func testTheTVIsOffOnlyWhenItsMediaPlayerSaysSo() throws {
        let remote = try familyRoom()
        XCTAssertTrue(remote.tvIsOff(mediaPlayerState: "off"))
        XCTAssertTrue(remote.tvIsOff(mediaPlayerState: "standby"))
        XCTAssertFalse(remote.tvIsOff(mediaPlayerState: "on"))
        XCTAssertFalse(remote.tvIsOff(mediaPlayerState: "playing"))
        // Can't tell, so the keys stay usable.
        XCTAssertFalse(remote.tvIsOff(mediaPlayerState: "unavailable"))
        XCTAssertFalse(remote.tvIsOff(mediaPlayerState: nil))
    }

    func testATVWithoutAMediaPlayerIsNeverOff() throws {
        let remote = try card("""
                    tv: { kind: samsung, remote: remote.tv }
        """)
        XCTAssertFalse(remote.tvIsOff(mediaPlayerState: "off"))
    }

    // MARK: The TV's app

    func testRunningAppIsAListedNonInputSource() throws {
        let remote = try familyRoom()
        let list = ["TV", "HDMI", "Netflix", "YouTube"]
        XCTAssertEqual(remote.runningApp(source: "Netflix", sourceList: list), "Netflix")
        // Cable, AirPlay and the receiver all report TV/HDMI.
        XCTAssertNil(remote.runningApp(source: "TV/HDMI", sourceList: list + ["TV/HDMI"]))
        XCTAssertNil(remote.runningApp(source: "TV", sourceList: list))
        XCTAssertNil(remote.runningApp(source: "HDMI2", sourceList: list + ["HDMI2"]))
        XCTAssertNil(remote.runningApp(source: nil, sourceList: list))
        XCTAssertNil(remote.runningApp(source: "", sourceList: list))
        // Not in the list: not sure, so not an app.
        XCTAssertNil(remote.runningApp(source: "Mystery", sourceList: list))
    }

    func testNoTVMeansNoApp() throws {
        let remote = try card("""
                    box: { kind: xfinity, remote: remote.xfinity }
        """)
        XCTAssertNil(remote.runningApp(source: "Netflix", sourceList: ["Netflix"]))
    }

    // MARK: Apps

    /// The household's own row, with the TV's names for each app.
    private func withApps() throws -> DashboardTVRemoteConfiguration {
        try card("""
                    title: Family Room
                    tv:
                      kind: samsung
                      remote: remote.family_room_samsung_tv
                      mediaPlayer: media_player.family_room_samsung_tv
                      power: script.family_room_samsung_tv_power_toggle
                      apps:
                        - { name: Xfinity, box: true, icon: tv }
                        - { name: Netflix }
                        - { name: Prime Video }
                        - { name: Max, source: HBO Max }
                        - { name: Hulu }
                    box:
                      kind: xfinity
                      remote: remote.xfinity
        """)
    }

    func testAppsAreParsedInOrder() throws {
        let remote = try withApps()
        XCTAssertEqual(remote.tvApps.map(\.name), ["Xfinity", "Netflix", "Prime Video", "Max", "Hulu"])
        XCTAssertEqual(remote.tvApps.first?.icon, "tv")
    }

    func testEachAppSelectsItsSource_andTheBoxItsInput() throws {
        let remote = try withApps()
        XCTAssertEqual(remote.tvApps.compactMap(remote.source(for:)), ["HDMI", "Netflix", "Prime Video", "HBO Max", "Hulu"])
        XCTAssertEqual(remote.appActions(remote.tvApps[3]),
                       [.openApp(mediaPlayer: tvPlayer, source: "HBO Max", powerScript: "script.family_room_samsung_tv_power_toggle")])
    }

    func testTheBoxsInputCanBeNamed() throws {
        let remote = try card("""
                    tv:
                      kind: samsung
                      remote: remote.tv
                      mediaPlayer: media_player.tv
                      apps: [{ name: Cable, box: true }]
                    box: { kind: xfinity, remote: remote.xfinity, input: HDMI2 }
        """)
        XCTAssertEqual(remote.source(for: remote.tvApps[0]), "HDMI2")
        XCTAssertEqual(remote.currentTVApp(source: "HDMI2")?.name, "Cable")
    }

    func testTheCurrentAppIsTheOneOnScreen() throws {
        let remote = try withApps()
        XCTAssertEqual(remote.currentTVApp(source: "Netflix")?.name, "Netflix")
        XCTAssertEqual(remote.currentTVApp(source: "HBO Max")?.name, "Max")
        XCTAssertEqual(remote.currentTVApp(source: "netflix ")?.name, "Netflix")
        // Samsung reports any HDMI port as TV/HDMI: that's the box.
        XCTAssertEqual(remote.currentTVApp(source: "TV/HDMI")?.name, "Xfinity")
        XCTAssertNil(remote.currentTVApp(source: "YouTube"))
        XCTAssertNil(remote.currentTVApp(source: nil))
        XCTAssertNil(remote.currentTVApp(source: ""))
    }

    func testAppsNeedAMediaPlayer() {
        XCTAssertEqual(error("""
                    tv:
                      kind: samsung
                      remote: remote.tv
                      apps: [{ name: Netflix }]
        """), .tvAppsNeedAMediaPlayer(cardType: "tv_remote"))
    }

    func testTheBoxsAppNeedsABox() {
        XCTAssertEqual(error("""
                    tv:
                      kind: samsung
                      remote: remote.tv
                      mediaPlayer: media_player.tv
                      apps: [{ name: Cable, box: true }]
        """), .tvAppNeedsABox("Cable", cardType: "tv_remote"))
    }

    func testAppsCanGoOnTheLockScreen_butOnlyOnesOnTheRow() throws {
        XCTAssertNoThrow(try card("""
                    tv: { kind: samsung, remote: remote.tv, mediaPlayer: media_player.tv, apps: [{ name: Netflix }] }
                    lockScreen: [open, app.Netflix]
        """))
        XCTAssertEqual(error("""
                    tv: { kind: samsung, remote: remote.tv, mediaPlayer: media_player.tv, apps: [{ name: Netflix }] }
                    lockScreen: [app.Hulu]
        """), .unknownLockScreenKey("app.Hulu", cardType: "tv_remote"))
    }

    // MARK: Opening an app

    private func tv(_ state: String) -> HAEntityState {
        HAEntityState(entityId: tvPlayer, state: state, attributes: [:])
    }

    func testOpeningAnAppOnAnOnTVJustSelectsIt() async {
        let client = MockHAClient()
        client.simulateConnected(entities: [tv("on")])
        await DashboardCardActionRouter.openApp("Netflix", on: tvPlayer, powerScript: "script.power", client: client, sleep: { _ in })
        XCTAssertEqual(client.serviceCallLog.map(\.method), ["selectSource:Netflix"])
    }

    func testOpeningAnAppOnAnOffTVTurnsItOnFirst_andWaitsForIt() async {
        let client = MockHAClient()
        client.simulateConnected(entities: [tv("off")])
        var naps = 0
        await DashboardCardActionRouter.openApp("Hulu", on: tvPlayer, powerScript: "script.power", client: client, sleep: { _ in
            naps += 1
            if naps == 3 { client.simulateConnected(entities: [self.tv("on")]) }
        })
        XCTAssertEqual(client.serviceCallLog.map { "\($0.entityId) \($0.method)" },
                       ["script.power runScript", "\(tvPlayer) selectSource:Hulu"])
        // Three half-seconds until it's on, then the settle.
        XCTAssertEqual(naps, 4)
    }

    func testWithoutAPowerScriptTheMediaPlayerTurnsItOn() async {
        let client = MockHAClient()
        client.simulateConnected(entities: [tv("standby")])
        var naps = 0
        await DashboardCardActionRouter.openApp("Netflix", on: tvPlayer, powerScript: nil, client: client, sleep: { _ in naps += 1 })
        XCTAssertEqual(client.serviceCallLog.map(\.method), ["turnOn", "selectSource:Netflix"])
        // It never came on: gave up after the timeout and sent it anyway.
        XCTAssertEqual(naps, 41)
    }
}

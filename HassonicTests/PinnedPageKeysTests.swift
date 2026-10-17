import XCTest
@testable import Hassonic

/// Which keys a pinned remote page puts on the Lock Screen, and what they send.
final class PinnedPageKeysTests: XCTestCase {

    private func page(_ cards: [DashboardCardConfiguration]) -> DashboardPageConfiguration {
        DashboardPageConfiguration(id: "remote", title: "Remote", systemIcon: "tv",
                                   sections: [DashboardSectionConfiguration(title: nil, cards: cards)])
    }

    private let samsung = DashboardTVRemoteConfiguration.Device(kind: .samsung, remote: "remote.tv", mediaPlayer: "media_player.tv", power: "script.tv_power")
    private let xfinity = DashboardTVRemoteConfiguration.Device(kind: .xfinity, remote: "remote.xfinity")

    func testTVAndBox_volumeOnTheTVAndPlayOnTheBox() {
        let keys = PinnedPageKeys.keys(for: page([.tvRemote(.init(tv: samsung, box: xfinity))]))

        XCTAssertEqual(keys.map(\.label), ["Power", "Volume Down", "Mute", "Volume Up", "Play/Pause"])
        XCTAssertEqual(keys[0].actions, [.init(kind: .runScript, entityId: "script.tv_power")])
        XCTAssertEqual(keys[3].actions, [.init(kind: .send, entityId: "remote.tv", command: "KEY_VOLUP")])
        XCTAssertEqual(keys[4].actions, [.init(kind: .send, entityId: "remote.xfinity", command: "play_pause")])
    }

    func testChosenKeys_openFirstAndAPlayPauseForEachDevice() {
        let keys = PinnedPageKeys.keys(for: page([.tvRemote(.init(tv: samsung, box: xfinity,
                                                                    lockScreen: ["open", "tv.playPause", "box.playPause"]))]))

        XCTAssertEqual(keys.map(\.id), ["open", "tv.playPause", "box.playPause"])
        XCTAssertEqual(keys.map(\.caption), ["Open", "Samsung TV", "Xfinity"])
        XCTAssertTrue(keys[0].opensPage)
        XCTAssertEqual(keys[0].systemImage, "tv")
        XCTAssertEqual(keys[1].actions, [.init(kind: .mediaPlayPause, entityId: "media_player.tv")])
        XCTAssertEqual(keys[2].actions, [.init(kind: .send, entityId: "remote.xfinity", command: "play_pause")])
    }

    func testTVOnly_playsOnItsMediaPlayer() {
        let keys = PinnedPageKeys.keys(for: page([.tvRemote(.init(tv: samsung))]))

        XCTAssertEqual(keys.last?.actions, [.init(kind: .mediaPlayPause, entityId: "media_player.tv")])
    }

    func testNoRemote_noKeys() {
        XCTAssertTrue(PinnedPageKeys.keys(for: page([])).isEmpty)
    }

    func testActionsRoundTrip() {
        let actions: [TVRemoteAction] = [
            .send(remote: "remote.tv", command: "KEY_MUTE"),
            .mediaPlayPause(mediaPlayer: "media_player.tv"),
            .samsungPlayPause(remote: "remote.tv"),
            .runScript(script: "script.tv_power"),
        ]
        XCTAssertEqual(actions.compactMap(PinnedPageKeys.action).compactMap(PinnedPageKeys.remoteAction), actions)
    }
}

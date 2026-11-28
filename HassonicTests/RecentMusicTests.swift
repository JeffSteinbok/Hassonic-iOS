import XCTest
@testable import Hassonic

@MainActor
final class RecentMusicTests: XCTestCase {

    private func item(_ id: String, thumbnail: String? = nil) -> RecentMusicItem {
        RecentMusicItem(contentType: "spotify://playlist", contentId: id, title: id, subtitle: "Playlist", thumbnail: thumbnail)
    }

    private func node(_ json: String) throws -> HABrowseMediaNode {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(HABrowseMediaNode.self, from: Data(json.utf8))
    }

    // MARK: - Recording

    func testRecordingPutsNewestFirstOnceEach() {
        var list: [RecentMusicItem] = []
        list = RecentMusic.recording(item("a"), in: list)
        list = RecentMusic.recording(item("b"), in: list)
        list = RecentMusic.recording(item("a"), in: list)
        XCTAssertEqual(list.map(\.id), ["a", "b"])
    }

    func testRecordingIsCapped() {
        var list: [RecentMusicItem] = []
        for index in 0..<30 { list = RecentMusic.recording(item("\(index)"), in: list) }
        XCTAssertEqual(list.count, RecentMusic.limit)
        XCTAssertEqual(list.first?.id, "29")
        XCTAssertEqual(list.last?.id, "10")
    }

    func testReplayWithoutArtKeepsEarlierArt() {
        let list = RecentMusic.recording(item("a", thumbnail: "https://art/a.jpg"), in: [])
        let replayed = RecentMusic.recording(item("a"), in: list)
        XCTAssertEqual(replayed.first?.thumbnail, "https://art/a.jpg")
    }

    // MARK: - Merging with the service's history

    func testMergeShowsAppHistoryFirstWithoutDuplicates() {
        let merged = RecentMusic.merged(local: [item("a"), item("b")], service: [item("b"), item("c")])
        XCTAssertEqual(merged.map(\.id), ["a", "b", "c"])
    }

    func testMergeIsCapped() {
        let service = (0..<30).map { item("s\($0)") }
        XCTAssertEqual(RecentMusic.merged(local: [item("a")], service: service).count, RecentMusic.limit)
    }

    // MARK: - Reading Home Assistant's media browser

    func testFindsSpotifysRecentlyPlayedFolder() throws {
        let root = try node("""
        {"title": "Media Library", "media_content_type": "spotify://library", "media_content_id": "library",
         "can_play": false, "can_expand": true, "children": [
            {"title": "Playlists", "media_content_type": "spotify://current_user_playlists",
             "media_content_id": "current_user_playlists", "can_play": false, "can_expand": true},
            {"title": "Recently played", "media_content_type": "spotify://current_user_recently_played",
             "media_content_id": "current_user_recently_played", "can_play": false, "can_expand": true}
        ]}
        """)
        XCTAssertEqual(RecentMusic.historyFolder(in: root)?.mediaContentId, "current_user_recently_played")
    }

    func testNoHistoryFolderWhenTheServiceHasNone() throws {
        let root = try node("""
        {"title": "Library", "can_expand": true, "children": [
            {"title": "Playlists", "media_content_type": "x", "media_content_id": "playlists", "can_expand": true}
        ]}
        """)
        XCTAssertNil(RecentMusic.historyFolder(in: root))
    }

    func testHistoryItemsArePlayableAndDeduplicated() throws {
        // Spotify lists a track once per play, so the same one can repeat.
        let folder = try node("""
        {"title": "Recently played", "can_expand": true, "children": [
            {"title": "Undertow", "media_class": "track", "media_content_type": "spotify://track",
             "media_content_id": "spotify:track:1", "can_play": true, "thumbnail": "https://i.scdn.co/1"},
            {"title": "Undertow", "media_class": "track", "media_content_type": "spotify://track",
             "media_content_id": "spotify:track:1", "can_play": true},
            {"title": "Folder", "media_content_type": "x", "media_content_id": "f", "can_play": false, "can_expand": true}
        ]}
        """)
        let items = RecentMusic.items(in: folder)
        XCTAssertEqual(items.map(\.id), ["spotify:track:1"])
        XCTAssertEqual(items.first?.subtitle, "Track")
        XCTAssertEqual(items.first?.thumbnail, "https://i.scdn.co/1")
    }

    func testFavoriteBecomesARecentWithItsIcon() {
        let favorite = MusicFavorite(displayName: "Chill", icon: "music.note.list", contentType: "playlist", contentId: "spotify:playlist:9")
        let recent = RecentMusic.item(from: favorite)
        XCTAssertEqual(recent.title, "Chill")
        XCTAssertEqual(recent.icon, "music.note.list")
        XCTAssertEqual(recent.subtitle, "Playlist")
        XCTAssertNil(recent.thumbnail)
    }

    func testClassNameReadsTypesFromEitherForm() {
        XCTAssertEqual(RecentMusic.className("spotify://playlist"), "Playlist")
        XCTAssertEqual(RecentMusic.className("album"), "Album")
        XCTAssertEqual(RecentMusic.className("radio_station"), "Radio Station")
    }

    // MARK: - Store

    func testStoreKeepsHistoryPerAccountAcrossLaunches() throws {
        let suite = "RecentMusicTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = RecentMusicStore(defaults: defaults)
        store.record(item("a"), account: "media_player.spotify_alex")
        store.record(item("b"), account: "media_player.spotify_sam")

        let relaunched = RecentMusicStore(defaults: defaults)
        XCTAssertEqual(relaunched.items(for: "media_player.spotify_alex").map(\.id), ["a"])
        XCTAssertEqual(relaunched.items(for: "media_player.spotify_sam").map(\.id), ["b"])
    }

    func testStoreMergesTheServicesHistory() async throws {
        let suite = "RecentMusicTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let root = try node("""
        {"title": "Library", "can_expand": true, "children": [
            {"title": "Recently played", "media_content_type": "spotify://current_user_recently_played",
             "media_content_id": "current_user_recently_played", "can_expand": true}
        ]}
        """)
        let folder = try node("""
        {"title": "Recently played", "can_expand": true, "children": [
            {"title": "Song", "media_class": "track", "media_content_type": "spotify://track",
             "media_content_id": "spotify:track:7", "can_play": true}
        ]}
        """)
        let store = RecentMusicStore(defaults: defaults)
        store.record(item("a"), account: "acct")
        await store.refreshFromService(account: "acct") { type, _ in
            HABrowseMediaResult(success: true, result: type == nil ? root : folder, error: nil)
        }
        XCTAssertEqual(store.items(for: "acct").map(\.id), ["a", "spotify:track:7"])
    }
}

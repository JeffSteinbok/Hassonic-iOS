import XCTest
@testable import Hassonic

/// Tests for zero, one, and multiple favorites configurations
/// and the FavoritePlaybackRouter destination routing.
@MainActor
final class FavoritesBarTests: XCTestCase {

    // MARK: - MusicFavorite helpers

    private func makeFavorite(
        displayName: String = "Test",
        icon: String = "music.note",
        contentType: String = "artist",
        contentId: String = "spotify:artist:1"
    ) -> MusicFavorite {
        MusicFavorite(displayName: displayName, icon: icon,
                      contentType: contentType, contentId: contentId)
    }

    // MARK: - Zero favorites: router never receives a request

    func testZeroFavoritesRouterHasNoAction() {
        let router = FavoritePlaybackRouter()
        XCTAssertNil(router.pendingAction)
        XCTAssertFalse(router.showSheet)
    }

    // MARK: - One favorite reads as a Favorites feature (not identity/account)

    func testOneFavoriteRouterQueuesAndShowsSheet() {
        let router = FavoritePlaybackRouter()
        let favorite = makeFavorite(displayName: "Taylor Swift", contentType: "artist",
                                    contentId: "spotify:artist:06HL4z0CvFAxyc27GXpf02")

        let accepted = router.requestPlay(.playMedia(
            contentType: favorite.contentType,
            contentId: favorite.contentId
        , displayName: "Test"))

        XCTAssertTrue(accepted, "Single favorite tap must be accepted")
        XCTAssertTrue(router.showSheet, "Sheet must be presented for one favorite")
        if case .playMedia(let ct, let id, _) = router.pendingAction {
            XCTAssertEqual(ct, "artist")
            XCTAssertEqual(id, "spotify:artist:06HL4z0CvFAxyc27GXpf02")
        } else {
            XCTFail("Expected .playMedia pending action for a single favorite")
        }
    }

    // MARK: - Multiple favorites: each routes correctly

    func testMultipleFavoritesEachRouteIndependently() {
        let items: [(String, String, String)] = [
            ("Artist A",   "artist",   "spotify:artist:1"),
            ("Playlist B", "playlist", "spotify:playlist:2"),
            ("Album C",    "album",    "spotify:album:3"),
        ]

        for (name, contentType, contentId) in items {
            let router = FavoritePlaybackRouter()
            let favorite = makeFavorite(displayName: name, contentType: contentType, contentId: contentId)

            let accepted = router.requestPlay(.playMedia(
                contentType: favorite.contentType,
                contentId: favorite.contentId
            , displayName: "Test"))

            XCTAssertTrue(accepted, "\(name): tap must be accepted")
            XCTAssertTrue(router.showSheet, "\(name): sheet must be shown")

            var confirmedContentId: String?
            router.sheetDismissed(picked: true) {
                if case .playMedia(_, let id, _) = $0 { confirmedContentId = id }
            }
            XCTAssertEqual(confirmedContentId, contentId,
                           "\(name): confirmed contentId must match the tapped favorite")
        }
    }

    // MARK: - Destination routing: picked=true fires playback, picked=false does not

    func testDestinationPickedFiresPlayback() {
        let router = FavoritePlaybackRouter()
        router.requestPlay(.playMedia(contentType: "playlist", contentId: "spotify:playlist:x", displayName: "Test"))

        var firedAction: PendingPlayAction?
        router.sheetDismissed(picked: true) { firedAction = $0 }

        guard case .playMedia(let ct, let id, _) = firedAction else {
            XCTFail("Expected .playMedia to fire after destination pick")
            return
        }
        XCTAssertEqual(ct, "playlist")
        XCTAssertEqual(id, "spotify:playlist:x")
        XCTAssertNil(router.pendingAction, "Pending action must be cleared")
        XCTAssertFalse(router.showSheet, "Sheet flag must be cleared")
    }

    func testDestinationCancelledDoesNotFirePlayback() {
        let router = FavoritePlaybackRouter()
        router.requestPlay(.playMedia(contentType: "album", contentId: "spotify:album:y", displayName: "Test"))

        var firedAction: PendingPlayAction?
        router.sheetDismissed(picked: false) { firedAction = $0 }

        XCTAssertNil(firedAction, "No playback must be triggered when user cancels destination sheet")
        XCTAssertNil(router.pendingAction)
        XCTAssertFalse(router.showSheet)
    }

    // MARK: - Duplicate-tap prevention across favorites

    func testSecondFavoriteTapWhileSheetOpenIsRejected() {
        let router = FavoritePlaybackRouter()

        let first  = router.requestPlay(.playMedia(contentType: "artist",   contentId: "spotify:artist:1", displayName: "Test"))
        let second = router.requestPlay(.playMedia(contentType: "playlist", contentId: "spotify:playlist:2", displayName: "Test"))

        XCTAssertTrue(first,  "First favorite tap must be accepted")
        XCTAssertFalse(second, "Second tap while sheet is open must be rejected")

        if case .playMedia(_, let id, _) = router.pendingAction {
            XCTAssertEqual(id, "spotify:artist:1", "Original pending action must not be overwritten")
        } else {
            XCTFail("Expected .playMedia pending action")
        }
    }

    func testNewTapAcceptedAfterPreviousDismissed() {
        let router = FavoritePlaybackRouter()
        router.requestPlay(.playMedia(contentType: "artist", contentId: "first", displayName: "Test"))
        router.sheetDismissed(picked: false) { _ in }

        let accepted = router.requestPlay(.playMedia(contentType: "album", contentId: "second", displayName: "Test"))
        XCTAssertTrue(accepted, "Tap must be accepted after prior sheet was dismissed")
    }
}

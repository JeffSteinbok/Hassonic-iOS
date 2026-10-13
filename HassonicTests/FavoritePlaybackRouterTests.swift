import XCTest
@testable import Hassonic

@MainActor
final class FavoritePlaybackRouterTests: XCTestCase {

    // MARK: - requestPlay always queues action and shows the sheet

    func testRequestPlayQueuesActionAndShowsSheet() {
        let router = FavoritePlaybackRouter()
        let accepted = router.requestPlay(.playMedia(contentType: "playlist", contentId: "spotify:playlist:123", displayName: "Test"))

        XCTAssertTrue(accepted)
        XCTAssertTrue(router.showSheet)
        if case .playMedia(let ct, let id, _) = router.pendingAction {
            XCTAssertEqual(ct, "playlist")
            XCTAssertEqual(id, "spotify:playlist:123")
        } else {
            XCTFail("Expected .playMedia pending action")
        }
    }

    /// Even when an active source exists (non-nil), favorites must show the sheet.
    func testRequestPlayShowsSheetRegardlessOfActiveSource() {
        let router = FavoritePlaybackRouter()
        // Simulates a caller that has an active source — the router must still queue.
        let accepted = router.requestPlay(.playMedia(contentType: "artist", contentId: "spotify:artist:456", displayName: "Test"))

        XCTAssertTrue(accepted)
        XCTAssertTrue(router.showSheet, "Sheet must be shown even when active source is available")
    }

    /// Stale lastPlayOnSourceName should not bypass the sheet — the router always queues.
    func testRequestPlayShowsSheetForStaleRememberedSource() {
        let router = FavoritePlaybackRouter()
        // Caller would have a stale fallback source; router still requires explicit selection.
        let accepted = router.requestPlay(.playMedia(contentType: "album", contentId: "spotify:album:789", displayName: "Test"))

        XCTAssertTrue(accepted)
        XCTAssertTrue(router.showSheet, "Sheet must be shown even for a stale remembered source")
    }

    func testRequestPlayShowsSheetWhenNoSourceAvailable() {
        let router = FavoritePlaybackRouter()
        let accepted = router.requestPlay(.playMedia(contentType: "track", contentId: "spotify:track:abc", displayName: "Test"))

        XCTAssertTrue(accepted)
        XCTAssertTrue(router.showSheet)
    }

    // MARK: - Cancellation: dismissing without picking fires no playback

    func testCancellationDoesNotFireOnConfirm() {
        let router = FavoritePlaybackRouter()
        router.requestPlay(.playMedia(contentType: "playlist", contentId: "spotify:playlist:123", displayName: "Test"))

        var confirmFired = false
        router.sheetDismissed(picked: false) { _ in confirmFired = true }

        XCTAssertFalse(confirmFired, "onConfirm must not be called when the user cancels")
        XCTAssertNil(router.pendingAction, "Pending action must be cleared on dismiss")
        XCTAssertFalse(router.showSheet)
    }

    // MARK: - Successful selection fires onConfirm with correct action

    func testSuccessfulSelectionFiresOnConfirmWithCorrectAction() {
        let router = FavoritePlaybackRouter()
        router.requestPlay(.playMedia(contentType: "playlist", contentId: "spotify:playlist:999", displayName: "Test"))

        var confirmedAction: PendingPlayAction?
        router.sheetDismissed(picked: true) { confirmedAction = $0 }

        if case .playMedia(let ct, let id, _) = confirmedAction {
            XCTAssertEqual(ct, "playlist")
            XCTAssertEqual(id, "spotify:playlist:999")
        } else {
            XCTFail("Expected .playMedia in onConfirm, got \(String(describing: confirmedAction))")
        }
        XCTAssertNil(router.pendingAction)
        XCTAssertFalse(router.showSheet)
    }

    func testSuccessfulSelectionWorksForAllFavoriteContentTypes() {
        for (contentType, contentId) in [
            ("artist",   "spotify:artist:1"),
            ("playlist", "spotify:playlist:2"),
            ("album",    "spotify:album:3"),
            ("track",    "spotify:track:4"),
        ] {
            let router = FavoritePlaybackRouter()
            router.requestPlay(.playMedia(contentType: contentType, contentId: contentId, displayName: "Test"))

            var confirmedContentType: String?
            router.sheetDismissed(picked: true) {
                if case .playMedia(let ct, _, _) = $0 { confirmedContentType = ct }
            }
            XCTAssertEqual(confirmedContentType, contentType, "Should fire for content type \(contentType)")
        }
    }

    // MARK: - Duplicate-tap prevention

    func testDuplicateTapWhilePendingIsRejected() {
        let router = FavoritePlaybackRouter()
        let first  = router.requestPlay(.playMedia(contentType: "playlist", contentId: "spotify:playlist:1", displayName: "Test"))
        let second = router.requestPlay(.playMedia(contentType: "playlist", contentId: "spotify:playlist:2", displayName: "Test"))

        XCTAssertTrue(first,   "First tap must be accepted")
        XCTAssertFalse(second, "Second tap while sheet is open must be rejected")
    }

    func testPendingActionIsNotReplacedBySecondTap() {
        let router = FavoritePlaybackRouter()
        router.requestPlay(.playMedia(contentType: "playlist", contentId: "original", displayName: "Test"))
        router.requestPlay(.playMedia(contentType: "track",    contentId: "replacement", displayName: "Test"))

        if case .playMedia(_, let id, _) = router.pendingAction {
            XCTAssertEqual(id, "original", "Pending action must not be replaced by a second tap")
        } else {
            XCTFail("Expected .playMedia pending action")
        }
    }

    // MARK: - After dismiss, a new tap is accepted

    func testNewTapIsAcceptedAfterDismissal() {
        let router = FavoritePlaybackRouter()
        router.requestPlay(.playMedia(contentType: "playlist", contentId: "first", displayName: "Test"))
        router.sheetDismissed(picked: false) { _ in }

        let accepted = router.requestPlay(.playMedia(contentType: "album", contentId: "second", displayName: "Test"))
        XCTAssertTrue(accepted, "A new tap must be accepted after the previous sheet was dismissed")
    }
}

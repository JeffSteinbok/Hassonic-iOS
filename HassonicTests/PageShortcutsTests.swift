import XCTest
@testable import Hassonic

/// What Shortcuts, Siri and the app icon offer, and where they lead.
@MainActor
final class PageShortcutsTests: XCTestCase {

    private func page(_ id: String, room: Bool = false) -> DashboardPageConfiguration {
        DashboardPageConfiguration(id: id, title: id.capitalized, systemIcon: "house", sections: [], isRoom: room)
    }

    func testMusicThenTabsThenRooms() {
        let pages = AppPage.all(in: [page("home"), page("kitchen", room: true), page("remote")])
        XCTAssertEqual(pages.map(\.id), ["music", "home", "remote", "kitchen"])
        XCTAssertEqual(pages.last?.title, "Kitchen")
    }

    func testEachOpensItsLink() {
        XCTAssertEqual(AppPage.music.url, URL(string: "hassonic://music"))
        XCTAssertEqual(AppPage.all(in: [page("kitchen", room: true)]).last?.url, URL(string: "hassonic://kitchen"))
    }

    func testTheOpenPageActionHandsTheLinkToTheApp() async throws {
        let kitchen = AppPage(id: "kitchen", title: "Kitchen", systemIcon: "refrigerator")
        _ = try await OpenPageIntent(page: kitchen).perform()
        XCTAssertEqual(PendingLink.shared.url, kitchen.url)
        PendingLink.shared.url = nil
    }

    func testOnlyOurQuickActionsOpenLinks() {
        let ours = UIApplicationShortcutItem(type: PageShortcuts.quickActionType, localizedTitle: "Remote", localizedSubtitle: nil,
                                             icon: nil, userInfo: ["url": "hassonic://remote" as NSString])
        let other = UIApplicationShortcutItem(type: "something-else", localizedTitle: "X")
        XCTAssertEqual(PageShortcuts.url(for: ours), URL(string: "hassonic://remote"))
        XCTAssertNil(PageShortcuts.url(for: other))
    }

    /// A room link opens the room (pushed on the first tab), a tab link its tab.
    func testTheRouterOpensWhatTheyLinkTo() {
        let router = AppRouter()
        router.setDashboardPages([page("home"), page("remote"), page("kitchen", room: true)])
        router.handle(url: URL(string: "hassonic://kitchen")!)
        XCTAssertEqual(router.roomPath, ["kitchen"])
        router.handle(url: URL(string: "hassonic://remote")!)
        XCTAssertEqual(router.selectedTab, .dashboard("remote"))
    }
}

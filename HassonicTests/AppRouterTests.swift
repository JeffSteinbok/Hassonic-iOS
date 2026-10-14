import XCTest
@testable import Hassonic

@MainActor
final class AppRouterTests: XCTestCase {

    func testNavigateToTabSetsSelectedTab() {
        let router = AppRouter()
        router.navigate(to: .tab(.music))
        XCTAssertEqual(router.selectedTab, .music)
    }

    func testNavigateToMusicPlayOnSetsMusicTabAndFlag() {
        let router = AppRouter()
        router.navigate(to: .musicPlayOn)
        XCTAssertEqual(router.selectedTab, .music)
        XCTAssertTrue(router.musicShowPlayOn)
    }

    func testHandleURLMusicPath() throws {
        let router = AppRouter()
        let url = try XCTUnwrap(URL(string: "hassonic://music"))
        router.handle(url: url)
        XCTAssertEqual(router.selectedTab, .music)
    }

    func testHandleURLMusicPlayOnPath() throws {
        let router = AppRouter()
        let url = try XCTUnwrap(URL(string: "hassonic://music/playon"))
        router.handle(url: url)
        XCTAssertEqual(router.selectedTab, .music)
        XCTAssertTrue(router.musicShowPlayOn)
    }

    func testHandleURLSecurityPath() throws {
        let router = AppRouter()
        let url = try XCTUnwrap(URL(string: "hassonic://security"))
        router.handle(url: url)
        XCTAssertEqual(router.selectedTab, .dashboard("security"))
    }

    /// The connection screen is the Settings sheet now, not a tab.
    func testHandleURLConnectionPathOpensSettings() throws {
        let router = AppRouter()
        router.navigate(to: .tab(.music))
        let url = try XCTUnwrap(URL(string: "hassonic://connection"))
        router.handle(url: url)
        XCTAssertEqual(router.presentedSheet, .settings)
        XCTAssertEqual(router.selectedTab, .music)
    }

    func testHandleURLUnknownSchemeIsIgnored() throws {
        let router = AppRouter()
        router.navigate(to: .tab(.music))
        let url = try XCTUnwrap(URL(string: "https://example.com/music"))
        router.handle(url: url)
        XCTAssertEqual(router.selectedTab, .music, "Unknown scheme should not change tab")
    }

    func testHandleURLUnknownHostIsIgnored() throws {
        let router = AppRouter()
        let url = try XCTUnwrap(URL(string: "hassonic://unknown/path"))
        router.handle(url: url)
        XCTAssertEqual(router.selectedTab, .connection, "Unknown host should leave tab unchanged")
    }

    func testConfiguredDashboardPageCanBeDeepLinked() throws {
        let router = AppRouter()
        let page = DashboardPageConfiguration(
            id: "climate",
            title: "Climate",
            systemIcon: "thermometer",
            sections: []
        )
        router.setDashboardPages([page])

        let url = try XCTUnwrap(URL(string: "hassonic://climate"))
        router.handle(url: url)

        XCTAssertEqual(router.selectedTab, .dashboard("climate"))
    }

    func testARoomLinkOpensTheRoomOnTheFirstTab() throws {
        let router = AppRouter()
        let home = DashboardPageConfiguration(id: "home", title: "Home", systemIcon: "house", sections: [])
        let remote = DashboardPageConfiguration(id: "remote", title: "Remote", systemIcon: "tv", sections: [])
        let kitchen = DashboardPageConfiguration(id: "kitchen", title: "Kitchen", systemIcon: "oven", sections: [], isRoom: true)
        router.setDashboardPages([home, kitchen, remote])
        router.navigate(to: .tab(.dashboard("remote")))

        router.handle(url: try XCTUnwrap(URL(string: "hassonic://kitchen")))

        XCTAssertEqual(router.selectedTab, .dashboard("home"))
        XCTAssertEqual(router.roomPath, ["kitchen"])
    }

    func testARoomThatGoesAwayLeavesThePath() {
        let router = AppRouter()
        let home = DashboardPageConfiguration(id: "home", title: "Home", systemIcon: "house", sections: [])
        let kitchen = DashboardPageConfiguration(id: "kitchen", title: "Kitchen", systemIcon: "oven", sections: [], isRoom: true)
        router.setDashboardPages([home, kitchen])
        router.openRoom("kitchen")

        router.setDashboardPages([home])

        XCTAssertEqual(router.roomPath, [])
    }

    func testRemovingSelectedDashboardPageSelectsFirstRemainingPage() {
        let router = AppRouter()
        let home = DashboardPageConfiguration(id: "home", title: "Home", systemIcon: "house", sections: [])
        let climate = DashboardPageConfiguration(
            id: "climate",
            title: "Climate",
            systemIcon: "thermometer",
            sections: []
        )
        router.setDashboardPages([home, climate])
        router.navigate(to: .tab(.dashboard("climate")))

        router.setDashboardPages([home])

        XCTAssertEqual(router.selectedTab, .dashboard("home"))
    }

    func testConnectedLandingSelectsFirstDashboardPage() {
        let router = AppRouter()
        let home = DashboardPageConfiguration(id: "home", title: "Home", systemIcon: "house", sections: [])

        router.selectConnectedLandingPage(from: [home])

        XCTAssertEqual(router.selectedTab, .dashboard("home"))
    }

    func testConnectedLandingFallsBackToMusicWithoutDashboardPages() {
        let router = AppRouter()

        router.selectConnectedLandingPage(from: [])

        XCTAssertEqual(router.selectedTab, .music)
    }

    // MARK: - Remembering the last tab

    private func freshDefaults() -> UserDefaults {
        let name = "AppRouterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private let home = DashboardPageConfiguration(id: "home", title: "Home", systemIcon: "house", sections: [])
    private let security = DashboardPageConfiguration(id: "security", title: "Security", systemIcon: "shield", sections: [])

    func testConnectedLandingReturnsToTheLastDashboardPage() {
        let defaults = freshDefaults()
        let before = AppRouter(lastTabStore: defaults)
        before.navigate(to: .tab(.dashboard("security")))

        let relaunched = AppRouter(lastTabStore: defaults)
        relaunched.selectConnectedLandingPage(from: [home, security])

        XCTAssertEqual(relaunched.selectedTab, .dashboard("security"))
    }

    func testConnectedLandingReturnsToMusic() {
        let defaults = freshDefaults()
        AppRouter(lastTabStore: defaults).navigate(to: .tab(.music))

        let relaunched = AppRouter(lastTabStore: defaults)
        relaunched.selectConnectedLandingPage(from: [home, security])

        XCTAssertEqual(relaunched.selectedTab, .music)
    }

    func testARemovedPageFallsBackToTheFirstPage() {
        let defaults = freshDefaults()
        AppRouter(lastTabStore: defaults).navigate(to: .tab(.dashboard("climate")))

        let relaunched = AppRouter(lastTabStore: defaults)
        relaunched.selectConnectedLandingPage(from: [home, security])

        XCTAssertEqual(relaunched.selectedTab, .dashboard("home"))
    }

    /// A drop shows the connection tab; reconnecting should go back to where
    /// you were, not to the connection tab or the first page.
    func testDisconnectDoesNotOverwriteTheRememberedTab() {
        let router = AppRouter(lastTabStore: freshDefaults())
        router.navigate(to: .tab(.dashboard("security")))
        router.navigate(to: .tab(.connection))

        router.selectConnectedLandingPage(from: [home, security])

        XCTAssertEqual(router.selectedTab, .dashboard("security"))
    }
}

final class AppTabOverflowTests: XCTestCase {
    func testFiveTabsAllFit() {
        XCTAssertFalse((0..<5).contains { AppTab.isInMore(tabIndex: $0, tabCount: 5) })
    }

    func testPastFiveTheFifthSlotOnwardMovesToMore() {
        XCTAssertEqual((0..<7).map { AppTab.isInMore(tabIndex: $0, tabCount: 7) },
                       [false, false, false, false, true, true, true])
    }
}

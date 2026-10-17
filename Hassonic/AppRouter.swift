import SwiftUI

enum AppTab: Hashable {
    case connection
    case music
    case assistant
    case dashboard(String)

    /// An iPhone tab bar shows five tabs; past that, the fifth slot becomes
    /// More and everything from there on is listed inside it.
    static let visibleTabLimit = 5

    static func isInMore(tabIndex: Int, tabCount: Int) -> Bool {
        tabCount > visibleTabLimit && tabIndex >= visibleTabLimit - 1
    }
}

enum AppDestination: Hashable {
    case tab(AppTab)
    case musicPlayOn
}

/// Sheets opened from the app menu or the connection-failed screen.
enum AppSheet: String, Identifiable {
    case settings
    case about

    var id: String { rawValue }
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var selectedTab: AppTab = .connection {
        didSet { rememberSelectedTab() }
    }
    @Published var musicShowPlayOn: Bool = false
    @Published var presentedSheet: AppSheet?
    /// The rooms pushed on the first page, which is where their tiles are.
    @Published var roomPath: [String] = []
    private var dashboardPageIDs: Set<String> = ["home", "security"]
    private var roomPageIDs: Set<String> = []
    /// The first tab, which carries the room tiles.
    private var roomsHostPageID: String?
    private var assistantEnabled = false

    func setAssistantEnabled(_ enabled: Bool) {
        assistantEnabled = enabled
        if !enabled, selectedTab == .assistant { selectedTab = .music }
    }

    /// Where the last tab picked is kept, so a relaunch or a reconnect lands
    /// back on it instead of the first page. Nil (tests) remembers nothing.
    private let lastTabStore: UserDefaults?
    private static let lastTabKey = StorageKeys.lastSelectedTab

    init(lastTabStore: UserDefaults? = nil) {
        self.lastTabStore = lastTabStore
    }

    func navigate(to destination: AppDestination) {
        switch destination {
        case .tab(let tab):
            selectedTab = tab
        case .musicPlayOn:
            selectedTab = .music
            musicShowPlayOn = true
        }
    }

    func setDashboardPages(_ pages: [DashboardPageConfiguration]) {
        let tabs = pages.filter { !$0.isRoom }
        roomPageIDs = Set(pages.filter(\.isRoom).map(\.id))
        roomsHostPageID = tabs.first?.id
        roomPath.removeAll { !roomPageIDs.contains($0) }
        dashboardPageIDs = Set(tabs.map(\.id))
        if case .dashboard(let selectedPageID) = selectedTab,
           !dashboardPageIDs.contains(selectedPageID) {
            selectedTab = tabs.first.map { .dashboard($0.id) } ?? .music
        }
    }

    /// Opens a room: the first tab, with the room pushed on it.
    func openRoom(_ roomID: String) {
        guard roomPageIDs.contains(roomID), let roomsHostPageID else { return }
        selectedTab = .dashboard(roomsHostPageID)
        roomPath = [roomID]
    }

    /// The tab last picked, if it still exists; otherwise the first page.
    func selectConnectedLandingPage(from pages: [DashboardPageConfiguration]) {
        if let remembered = rememberedTab(), tab(remembered, existsIn: pages) {
            selectedTab = remembered
            return
        }
        selectedTab = pages.first.map { .dashboard($0.id) } ?? .music
    }

    /// `.connection` is only the selection before anything's loaded, so it's
    /// never a place to come back to.
    private func rememberSelectedTab() {
        guard let lastTabStore else { return }
        switch selectedTab {
        case .connection:
            return
        case .music:
            lastTabStore.set("music", forKey: Self.lastTabKey)
        case .assistant:
            lastTabStore.set("assistant", forKey: Self.lastTabKey)
        case .dashboard(let pageID):
            lastTabStore.set("dashboard:\(pageID)", forKey: Self.lastTabKey)
        }
    }

    private func rememberedTab() -> AppTab? {
        guard let stored = lastTabStore?.string(forKey: Self.lastTabKey) else { return nil }
        if stored == "music" { return .music }
        if stored == "assistant" { return .assistant }
        if stored.hasPrefix("dashboard:") { return .dashboard(String(stored.dropFirst("dashboard:".count))) }
        return nil
    }

    private func tab(_ tab: AppTab, existsIn pages: [DashboardPageConfiguration]) -> Bool {
        switch tab {
        case .connection: return false
        case .music: return true
        case .assistant: return assistantEnabled
        case .dashboard(let pageID): return pages.contains { $0.id == pageID }
        }
    }

    nonisolated static let schemes: Set<String> = ["hassonic"]

    func handle(url: URL) {
        guard let scheme = url.scheme?.lowercased(), Self.schemes.contains(scheme) else { return }
        let host = url.host ?? ""
        let subpath = url.pathComponents.filter { $0 != "/" }.first

        switch (host, subpath) {
        case ("assistant", _) where assistantEnabled:
            navigate(to: .tab(.assistant))
        case ("music", "playon"):
            navigate(to: .musicPlayOn)
        case ("music", _):
            navigate(to: .tab(.music))
        case ("connection", _), ("settings", _):
            presentedSheet = .settings
        case ("about", _):
            presentedSheet = .about
        case let (roomID, _) where roomPageIDs.contains(roomID):
            openRoom(roomID)
        case let (pageID, _) where dashboardPageIDs.contains(pageID):
            navigate(to: .tab(.dashboard(pageID)))
        default:
            break
        }
    }
}

import AppIntents
import SwiftUI
import UIKit

// Ways into a page from outside the app: an "Open Page" action for Shortcuts,
// Siri, Spotlight and the Action button, and quick actions on the app icon.
// All of them end in the page's `hassonic://<id>` link.

/// A page a shortcut can open: Music, or any page or room in the config.
struct AppPage: AppEntity, Codable, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Page"
    static let defaultQuery = AppPageQuery()

    let id: String
    let title: String
    let systemIcon: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", image: .init(systemName: systemIcon))
    }

    var url: URL { URL(string: "hassonic://\(id)") ?? URL(string: "hassonic://music")! }

    static let music = AppPage(id: "music", title: "Music", systemIcon: "music.note")

    /// Music, then the tabs, then the rooms, in config order.
    static func all(in pages: [DashboardPageConfiguration]) -> [AppPage] {
        let tabs = pages.filter { !$0.isRoom }
        let rooms = pages.filter(\.isRoom)
        return [music] + (tabs + rooms).map { AppPage(id: $0.id, title: $0.title, systemIcon: $0.systemIcon) }
    }
}

/// The pages as of the last config the app loaded. Kept in UserDefaults so
/// Shortcuts and Siri can list them without the app on screen.
enum PageShortcuts {
    private static let key = "hassonic.shortcutPages"
    /// The app-icon menu shows four at most.
    private static let quickActionCount = 4
    static let quickActionType = "open-page"

    static var pages: [AppPage] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let pages = try? JSONDecoder().decode([AppPage].self, from: data) else { return [.music] }
        return pages
    }

    /// Called whenever the config changes: refreshes what Shortcuts, Siri
    /// and the app icon offer.
    @MainActor
    static func update(for configuration: [DashboardPageConfiguration]) {
        let pages = AppPage.all(in: configuration)
        guard pages != self.pages || UIApplication.shared.shortcutItems?.isEmpty != false else { return }
        if let data = try? JSONEncoder().encode(pages) {
            UserDefaults.standard.set(data, forKey: key)
        }
        HassonicShortcuts.updateAppShortcutParameters()
        UIApplication.shared.shortcutItems = pages.prefix(quickActionCount).map { page in
            UIApplicationShortcutItem(
                type: quickActionType,
                localizedTitle: page.title,
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: page.systemIcon),
                userInfo: ["url": page.url.absoluteString as NSString]
            )
        }
    }

    /// The link a quick action opens, if it's one of ours.
    static func url(for item: UIApplicationShortcutItem) -> URL? {
        guard item.type == quickActionType, let string = item.userInfo?["url"] as? String else { return nil }
        return URL(string: string)
    }
}

struct AppPageQuery: EntityQuery {
    func entities(for identifiers: [AppPage.ID]) async throws -> [AppPage] {
        PageShortcuts.pages.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [AppPage] {
        PageShortcuts.pages
    }
}

/// Links that arrive from outside SwiftUI (an intent, a quick action) for the
/// app to open once it's on screen.
@MainActor
final class PendingLink: ObservableObject {
    static let shared = PendingLink()
    @Published var url: URL?
}

struct OpenPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Page"
    static let description = IntentDescription("Opens a page or room in the app.")
    static let openAppWhenRun = true

    @Parameter(title: "Page")
    var page: AppPage

    init() {}

    init(page: AppPage) {
        self.page = page
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$page)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingLink.shared.url = page.url
        return .result()
    }
}

/// Ready-made in the Shortcuts app and for Siri: one per page ("Open Kitchen
/// in Steinbok Home"), and music on a speaker (see MusicIntents).
struct HassonicShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenPageIntent(),
            phrases: [
                "Open \(\.$page) in \(.applicationName)",
                "Show \(\.$page) in \(.applicationName)",
                "Open \(.applicationName)",
            ],
            shortTitle: "Open Page",
            systemImageName: "square.grid.2x2"
        )
        AppShortcut(
            intent: PlayOnSpeakerIntent(),
            phrases: [
                "Play music on \(\.$speaker) in \(.applicationName)",
                "Play \(\.$favorite) in \(.applicationName)",
                "Play on \(\.$speaker) with \(.applicationName)",
            ],
            shortTitle: "Play on Speaker",
            systemImageName: "hifispeaker.2"
        )
    }
}

/// The ☰ menu's "Add to Shortcuts": how to get to this page from the Home
/// Screen, Siri or the Action button.
struct AddPageShortcutSheet: View {
    let page: AppPage

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(page.title, systemImage: page.systemIcon)
                        .font(.title3.weight(.semibold))
                }
                Section("Siri") {
                    Text("Say “Open \(page.title) in \(AppIdentity.name)”.")
                }
                Section {
                    ShortcutsLink()
                        .shortcutsLinkStyle(.automaticOutline)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } header: {
                    Text("Home Screen")
                } footer: {
                    Text("In Shortcuts, open \(AppIdentity.name), long-press Open \(page.title), and choose Add to Home Screen. The Action button (Settings › Action Button › Shortcut) and Control Center can run it too.")
                }
            }
            .navigationTitle("Add to Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Catches quick actions: from launch (the scene's connection options) and
/// while running (`performActionFor`).
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let item = connectionOptions.shortcutItem, let url = PageShortcuts.url(for: item) else { return }
        Task { @MainActor in PendingLink.shared.url = url }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        guard let url = PageShortcuts.url(for: shortcutItem) else { return completionHandler(false) }
        Task { @MainActor in PendingLink.shared.url = url }
        completionHandler(true)
    }
}

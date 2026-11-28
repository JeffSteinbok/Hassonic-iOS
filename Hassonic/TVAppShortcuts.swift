import AppIntents
import Foundation

// Apps on a TV by voice: "Hey Siri, open Netflix on the TV with Steinbok
// Home". Each app on a `tv_remote` card's app row is one; like a Live
// Activity key, it runs in the background from the saved sign-in.

/// An app on one TV's app row.
struct TVAppEntity: AppEntity, Codable, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "TV App"
    static let defaultQuery = TVAppQuery()

    /// The TV's media player and the app's name.
    let id: String
    let name: String
    /// Which TV, e.g. "Family Room TV".
    let tvName: String
    let systemImage: String
    let mediaPlayer: String
    let source: String
    var powerScript: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(tvName)",
            image: .init(systemName: systemImage),
            synonyms: ["\(name) on the \(tvName)", "\(name) on \(tvName)"]
        )
    }

    var actions: [TVRemoteAction] {
        [.openApp(mediaPlayer: mediaPlayer, source: source, powerScript: powerScript)]
    }

    /// Every app on every TV remote card, in config order, each once.
    static func all(in pages: [DashboardPageConfiguration]) -> [TVAppEntity] {
        var seen = Set<String>()
        return pages.flatMap { page in
            page.sections.flatMap(\.cards).flatMap { card -> [TVAppEntity] in
                guard case .tvRemote(let remote) = card, let tv = remote.tv, let mediaPlayer = tv.mediaPlayer else { return [] }
                let tvName = "\(remote.title ?? page.title) TV"
                return remote.tvApps.compactMap { app in
                    guard let source = remote.source(for: app) else { return nil }
                    let entity = TVAppEntity(
                        id: "\(mediaPlayer)/\(app.name)", name: app.name, tvName: tvName,
                        systemImage: app.icon ?? (app.isBox ? "tv.inset.filled" : "play.tv"),
                        mediaPlayer: mediaPlayer, source: source, powerScript: tv.power
                    )
                    return seen.insert(entity.id).inserted ? entity : nil
                }
            }
        }
    }
}

/// The apps as of the last config the app loaded, kept in UserDefaults so
/// Siri can open one with the app not running.
enum TVAppShortcuts {
    private static let key = "hassonic.shortcutTVApps"

    static var apps: [TVAppEntity] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let apps = try? JSONDecoder().decode([TVAppEntity].self, from: data) else { return [] }
        return apps
    }

    /// Saves the config's apps; true when they changed, so Siri's phrases
    /// need refreshing.
    @discardableResult
    static func update(for configuration: [DashboardPageConfiguration]) -> Bool {
        let apps = TVAppEntity.all(in: configuration)
        guard apps != self.apps, let data = try? JSONEncoder().encode(apps) else { return false }
        UserDefaults.standard.set(data, forKey: key)
        return true
    }
}

struct TVAppQuery: EntityStringQuery {
    func entities(for identifiers: [TVAppEntity.ID]) async throws -> [TVAppEntity] {
        TVAppShortcuts.apps.filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [TVAppEntity] {
        TVAppShortcuts.apps.filter {
            $0.name.localizedCaseInsensitiveContains(string) || string.localizedCaseInsensitiveContains($0.name)
        }
    }

    func suggestedEntities() async throws -> [TVAppEntity] {
        TVAppShortcuts.apps
    }
}

struct OpenTVAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Open App on TV"
    static let description = IntentDescription("Opens an app on a TV, turning it on first if it's off.")

    @Parameter(title: "App")
    var app: TVAppEntity

    init() {}

    init(app: TVAppEntity) {
        self.app = app
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$app)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let client = HAWebSocketClient.shared
        guard await HAConnectionBootstrapper.connectAndWait(client: client, for: app.mediaPlayer) else {
            return .result(dialog: "I couldn't reach Home Assistant.")
        }
        await DashboardCardActionRouter.run(app.actions, client: client)
        return .result(dialog: "Opening \(app.name) on the \(app.tvName).")
    }
}

import AppIntents
import UIKit

// Music by voice: "Hey Siri, play music on the Kitchen in Steinbok Home", or
// "play Chill in Steinbok Home" (Siri then asks which speaker). Runs in the
// background, connecting from the saved sign-in like a Live Activity button.
// Speakers, favorites and accounts are the ones in the config.

/// A speaker or group from the config, across every media account.
struct SpeakerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Speaker"
    static let defaultQuery = SpeakerQuery()

    let id: String
    let name: String
    let icon: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: icon))
    }
}

struct SpeakerQuery: EntityStringQuery {
    @MainActor
    private func all() -> [SpeakerEntity] {
        var seen = Set<String>()
        return MusicByVoice.accounts().flatMap(\.zones)
            .filter { $0.isEnabled && $0.sourceName != nil && seen.insert($0.entityId).inserted }
            .map { SpeakerEntity(id: $0.entityId, name: $0.displayName, icon: $0.icon) }
    }

    func entities(for identifiers: [String]) async throws -> [SpeakerEntity] {
        await all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [SpeakerEntity] {
        await all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [SpeakerEntity] {
        await all()
    }
}

/// A favorite from the config, across every media account.
struct FavoriteEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Favorite"
    static let defaultQuery = FavoriteQuery()

    let id: String
    let name: String
    let icon: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: icon))
    }
}

struct FavoriteQuery: EntityStringQuery {
    @MainActor
    private func all() -> [FavoriteEntity] {
        var seen = Set<String>()
        return MusicByVoice.accounts().flatMap(\.favorites)
            .filter { seen.insert($0.contentId).inserted }
            .map { FavoriteEntity(id: $0.contentId, name: $0.displayName, icon: $0.icon) }
    }

    func entities(for identifiers: [String]) async throws -> [FavoriteEntity] {
        await all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [FavoriteEntity] {
        await all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [FavoriteEntity] {
        await all()
    }
}

/// A media account from the config ("Jamie", "Morgan").
struct MediaAccountEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
    static let defaultQuery = MediaAccountQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct MediaAccountQuery: EntityQuery {
    @MainActor
    private func all() -> [MediaAccountEntity] {
        MusicByVoice.accounts().map { MediaAccountEntity(id: $0.id, name: $0.displayName) }
    }

    func entities(for identifiers: [String]) async throws -> [MediaAccountEntity] {
        await all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [MediaAccountEntity] {
        await all()
    }
}

struct PlayOnSpeakerIntent: AppIntent {
    static let title: LocalizedStringResource = "Play on Speaker"
    static let description = IntentDescription(
        "Plays a favorite on a speaker, or moves what's playing there. Uses the account picked in the app unless you choose one."
    )

    @Parameter(title: "Speaker")
    var speaker: SpeakerEntity

    @Parameter(title: "Favorite", description: "Leave empty to move what's already playing.")
    var favorite: FavoriteEntity?

    @Parameter(title: "Account")
    var account: MediaAccountEntity?

    init() {}

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$favorite) on \(\.$speaker)") {
            \.$account
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await MusicByVoice.play(favoriteId: favorite?.id, onSpeaker: speaker.id, accountId: account?.id)
        return .result(dialog: "\(reply)")
    }
}

/// The work behind the intent, kept apart from App Intents' types.
@MainActor
enum MusicByVoice {
    static func accounts() -> [MediaAccount] {
        AppConfigurationLoader.launchConfiguration().map { MusicZones.make(from: $0.media) } ?? []
    }

    /// The account picked on the Music tab, or the first.
    static func account(id: String?) -> MediaAccount? {
        let accounts = accounts()
        let selected = id ?? UserDefaults.standard.string(forKey: StorageKeys.selectedMediaAccount)
        return accounts.first { $0.id == selected } ?? accounts.first
    }

    /// Moves the account to the speaker and starts the favorite (or carries
    /// on with what was playing). Returns what Siri says.
    static func play(favoriteId: String?, onSpeaker speakerId: String, accountId: String?) async -> String {
        guard let config = AppConfigurationLoader.launchConfiguration(),
              let account = account(id: accountId) else {
            return "There's no music set up in the app yet."
        }
        guard let zone = account.zones.first(where: { $0.entityId == speakerId }),
              let source = zone.sourceName else {
            return "That speaker isn't one of \(account.displayName)'s."
        }
        let favorite = favoriteId.flatMap { id in account.favorites.first { $0.contentId == id } }
        if favoriteId != nil, favorite == nil {
            return "That favorite isn't one of \(account.displayName)'s."
        }

        let client = HAWebSocketClient.shared
        guard await HAConnectionBootstrapper.connectAndWait(client: client, for: account.entityId) else {
            return "I couldn't reach Home Assistant."
        }

        switch await client.selectSourceConfirmed(account.entityId, source: source) {
        case .alreadyActive, .confirmed:
            return start(favorite, on: zone, source: source, account: account, client: client)
        case .error(let message):
            return "I couldn't switch to \(zone.displayName): \(message)"
        case .timeout:
            break
        }

        // The speaker isn't on this account. Claiming it is a long voice-
        // assistant round trip, longer than Siri waits, so it finishes in the
        // background and Siri answers now.
        guard let claim = config.speakerClaim else {
            return "\(zone.displayName) isn't on \(account.displayName)'s account, and nothing's set up to move it."
        }
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Claim speaker")
        Task { @MainActor in
            defer { UIApplication.shared.endBackgroundTask(backgroundTask) }
            let outcome = await client.claimSpeaker(using: claim, account: account.displayName, speaker: zone.displayName,
                                                    contentName: favorite?.displayName, onStatus: { _ in })
            guard case .confirmed = outcome else {
                Log.music.note("Siri: couldn't claim \(zone.displayName) for \(account.displayName): \(String(describing: outcome))")
                return
            }
            // Its `source` lags the handoff; the claim confirming is enough.
            _ = await client.selectSourceConfirmed(account.entityId, source: source, timeout: .seconds(15))
            _ = start(favorite, on: zone, source: source, account: account, client: client)
        }
        return "Moving \(zone.displayName) to \(account.displayName)'s account. It'll start in a few seconds."
    }

    private static func start(_ favorite: MusicFavorite?, on zone: MusicZone, source: String,
                              account: MediaAccount, client: HAWebSocketClient) -> String {
        // The Now Playing card's fallback for when HA omits `source` while paused.
        UserDefaults.standard.set(source, forKey: StorageKeys.lastPlayOnSource(account: account.entityId))
        if let favorite {
            client.playMedia(account.entityId, contentType: favorite.contentType, contentId: favorite.contentId)
            return "Playing \(favorite.displayName) on \(zone.displayName)."
        }
        switch client.entity(account.entityId)?.state {
        case "playing":
            return "Moved to \(zone.displayName)."
        case "paused":
            client.mediaPlayPause(account.entityId)
            return "Playing on \(zone.displayName)."
        default:
            return "\(zone.displayName) is ready, but nothing's playing. Say which favorite."
        }
    }
}

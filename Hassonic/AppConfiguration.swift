import Foundation
import Yams

/// The whole app configuration: dashboard pages, media accounts and zones,
/// and how to claim a speaker for an account.
///
/// One document rather than three. `pages` was `DashboardConfig.yaml`, `media`
/// was `MusicConfig.json`, and `speakerClaim` was hardcoded Swift — splitting
/// them meant two formats, two lifecycles, and settings that had nowhere to
/// live at all.
struct AppConfiguration: Decodable, Equatable {
    let version: Int
    let pages: [DashboardPageConfiguration]
    let media: MediaConfiguration
    /// Absent when nothing in the house can claim a speaker for an account —
    /// a single-account household needs none of it.
    let speakerClaim: SpeakerClaimConfig?

    private enum CodingKeys: String, CodingKey {
        case version, pages, media, speakerClaim
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        pages = try c.decode([DashboardPageConfiguration].self, forKey: .pages)
        // A dashboard-only config is legitimate — someone may not use the
        // music tab at all — so an absent media block is empty, not an error.
        media = try c.decodeIfPresent(MediaConfiguration.self, forKey: .media) ?? MediaConfiguration()
        speakerClaim = try c.decodeIfPresent(SpeakerClaimConfig.self, forKey: .speakerClaim)
    }

    init(
        version: Int = 1,
        pages: [DashboardPageConfiguration],
        media: MediaConfiguration = MediaConfiguration(),
        speakerClaim: SpeakerClaimConfig? = nil
    ) {
        self.version = version
        self.pages = pages
        self.media = media
        self.speakerClaim = speakerClaim
    }

    var dashboard: DashboardConfiguration {
        DashboardConfiguration(version: version, pages: pages)
    }

    func validated() throws -> AppConfiguration {
        _ = try dashboard.validated()
        try media.validate()
        return self
    }
}

/// Media accounts and the zones each can cast to.
struct MediaConfiguration: Decodable, Equatable {
    var accounts: [MediaAccountConfiguration] = []
    /// Naming for whoever actually serves the music. Absent means the app
    /// says nothing about a provider at all — no logo, no "open the app"
    /// button, generic copy — which is the right default, since every
    /// service call underneath is stock `media_player`.
    var provider: MediaProviderConfiguration?

    private enum CodingKeys: String, CodingKey { case accounts, provider }

    init() {}

    init(accounts: [MediaAccountConfiguration], provider: MediaProviderConfiguration? = nil) {
        self.accounts = accounts
        self.provider = provider
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent([MediaAccountConfiguration].self, forKey: .accounts) { accounts = v }
        provider = try c.decodeIfPresent(MediaProviderConfiguration.self, forKey: .provider)
    }

    func validate() throws {
        var ids = Set<String>()
        for account in accounts {
            guard !account.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppConfigurationError.missingAccountID
            }
            guard ids.insert(account.id).inserted else {
                throw AppConfigurationError.duplicateAccountID(account.id)
            }
            guard !account.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppConfigurationError.missingAccountDisplayName(account.id)
            }
            guard account.entityId.hasPrefix("media_player.") else {
                throw AppConfigurationError.invalidAccountEntity(
                    accountID: account.id,
                    entityID: account.entityId
                )
            }
            try account.validateLiveActivityZones()
        }
    }
}

/// What to call the music service, and how to hand off to its app.
///
/// Purely presentation — nothing here changes a service call. It exists so
/// the app doesn't tell a Sonos household to "start playing something in
/// Spotify".
struct MediaProviderConfiguration: Decodable, Equatable {
    /// Shown in copy: "Start playing something in {name}".
    let name: String
    /// URL scheme for the provider's own app, e.g. `spotify:`. Omit and the
    /// open-the-app affordances disappear rather than pointing nowhere.
    var urlScheme: String?
    /// Asset-catalog image name for the logo button. Omit for no logo.
    var logoAsset: String?

    private enum CodingKeys: String, CodingKey { case name, urlScheme, logoAsset }

    init(name: String, urlScheme: String? = nil, logoAsset: String? = nil) {
        self.name = name
        self.urlScheme = urlScheme
        self.logoAsset = logoAsset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        urlScheme = try c.decodeIfPresent(String.self, forKey: .urlScheme)
        logoAsset = try c.decodeIfPresent(String.self, forKey: .logoAsset)
    }

    var appURL: URL? { urlScheme.flatMap(URL.init(string:)) }
}

struct MediaAccountConfiguration: Decodable, Equatable {
    let id: String
    /// Spoken aloud when claiming a speaker, and matched against the reply —
    /// this is not just a label. It has to match the account name the voice
    /// assistant knows.
    let displayName: String
    let entityId: String
    var favorites: [MediaFavoriteConfiguration] = []
    var speakers: [MediaSpeakerConfiguration] = []
    var groups: [MediaGroupConfiguration] = []
    /// The speaker Live Activity's zone buttons, in order: entity ids of this
    /// account's speakers or groups. Absent means the first few castable
    /// zones, groups first.
    var liveActivityZones: [String]?

    /// More than this crowds the lock screen row and the expanded island.
    static let maxLiveActivityZones = 4

    private enum CodingKeys: String, CodingKey {
        case id, displayName, entityId, favorites, speakers, groups, liveActivityZones
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        entityId = try c.decode(String.self, forKey: .entityId)
        if let v = try c.decodeIfPresent([MediaFavoriteConfiguration].self, forKey: .favorites) { favorites = v }
        if let v = try c.decodeIfPresent([MediaSpeakerConfiguration].self, forKey: .speakers) { speakers = v }
        if let v = try c.decodeIfPresent([MediaGroupConfiguration].self, forKey: .groups) { groups = v }
        liveActivityZones = try c.decodeIfPresent([String].self, forKey: .liveActivityZones)
    }

    /// Each entry has to be a zone the activity could actually cast to: one
    /// of this account's enabled speakers or groups with a `sourceName`.
    fileprivate func validateLiveActivityZones() throws {
        guard let liveActivityZones else { return }
        guard liveActivityZones.count <= Self.maxLiveActivityZones else {
            throw AppConfigurationError.tooManyLiveActivityZones(accountID: id, count: liveActivityZones.count)
        }
        let castable = Set(
            speakers.filter { $0.isEnabled && $0.sourceName != nil }.map(\.entityId)
                + groups.filter { $0.isEnabled && $0.sourceName != nil }.map(\.entityId)
        )
        var seen = Set<String>()
        for entityID in liveActivityZones {
            guard seen.insert(entityID).inserted else {
                throw AppConfigurationError.duplicateLiveActivityZone(accountID: id, entityID: entityID)
            }
            guard castable.contains(entityID) else {
                throw AppConfigurationError.unknownLiveActivityZone(accountID: id, entityID: entityID)
            }
        }
    }
}

struct MediaFavoriteConfiguration: Decodable, Equatable {
    let displayName: String
    let icon: String
    /// Passed straight through as `media_content_type` / `media_content_id`
    /// on `media_player.play_media`.
    let contentType: String
    let contentId: String
}

struct MediaProxyConfiguration: Decodable, Equatable {
    let entityId: String
    let inputSource: String
}

struct MediaSpeakerConfiguration: Decodable, Equatable {
    let entityId: String
    let displayName: String
    /// Matching entry in the account entity's `source_list`, if any.
    var sourceName: String?
    let icon: String
    var isEnabled: Bool = true
    var defaultVolume: Double?
    var proxy: MediaProxyConfiguration?

    private enum CodingKeys: String, CodingKey {
        case entityId, displayName, sourceName, icon, isEnabled, defaultVolume, proxy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entityId = try c.decode(String.self, forKey: .entityId)
        displayName = try c.decode(String.self, forKey: .displayName)
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName)
        icon = try c.decode(String.self, forKey: .icon)
        if let v = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) { isEnabled = v }
        defaultVolume = try c.decodeIfPresent(Double.self, forKey: .defaultVolume)
        proxy = try c.decodeIfPresent(MediaProxyConfiguration.self, forKey: .proxy)
    }
}

struct MediaGroupConfiguration: Decodable, Equatable {
    let entityId: String
    let displayName: String
    var sourceName: String?
    let icon: String
    var isEnabled: Bool = true
    var memberEntityIds: [String] = []

    private enum CodingKeys: String, CodingKey {
        case entityId, displayName, sourceName, icon, isEnabled, memberEntityIds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entityId = try c.decode(String.self, forKey: .entityId)
        displayName = try c.decode(String.self, forKey: .displayName)
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName)
        icon = try c.decode(String.self, forKey: .icon)
        if let v = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) { isEnabled = v }
        if let v = try c.decodeIfPresent([String].self, forKey: .memberEntityIds) { memberEntityIds = v }
    }
}

enum AppConfigurationError: LocalizedError, Equatable {
    case missingAccountID
    case duplicateAccountID(String)
    case missingAccountDisplayName(String)
    case invalidAccountEntity(accountID: String, entityID: String)
    case tooManyLiveActivityZones(accountID: String, count: Int)
    case duplicateLiveActivityZone(accountID: String, entityID: String)
    case unknownLiveActivityZone(accountID: String, entityID: String)

    var errorDescription: String? {
        switch self {
        case .missingAccountID:
            return "Every media account must have a non-empty id."
        case .duplicateAccountID(let id):
            return "Media account id '\(id)' is duplicated."
        case .missingAccountDisplayName(let id):
            return "Media account '\(id)' must have a displayName — it is spoken aloud when claiming a speaker."
        case .invalidAccountEntity(let accountID, let entityID):
            return "Media account '\(accountID)' needs a media_player.* entity, not '\(entityID)'."
        case .tooManyLiveActivityZones(let accountID, let count):
            return "Media account '\(accountID)' lists \(count) liveActivityZones; the Live Activity fits at most \(MediaAccountConfiguration.maxLiveActivityZones)."
        case .duplicateLiveActivityZone(let accountID, let entityID):
            return "Media account '\(accountID)' lists '\(entityID)' in liveActivityZones more than once."
        case .unknownLiveActivityZone(let accountID, let entityID):
            return "Media account '\(accountID)' lists '\(entityID)' in liveActivityZones, but it isn't one of its enabled speakers or groups with a sourceName."
        }
    }
}

enum AppConfigurationParser {
    static func parse(_ yaml: String) throws -> AppConfiguration {
        do {
            return try YAMLDecoder().decode(AppConfiguration.self, from: yaml).validated()
        } catch let error as DecodingError {
            throw DashboardConfigurationError.malformedYAML(DashboardDecodingErrorFormatter.describe(error))
        }
    }
}

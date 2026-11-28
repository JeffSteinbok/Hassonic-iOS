import Foundation

/// Something that was played and can be started again with one tap: an
/// album, playlist, artist or track, with the art to show for it.
struct RecentMusicItem: Codable, Identifiable, Equatable {
    /// Passed straight back to `media_player.play_media`.
    let contentType: String
    let contentId: String
    let title: String
    /// "Playlist", "Album"… shown under the title.
    var subtitle: String?
    /// A Home Assistant image path or a full URL.
    var thumbnail: String?
    /// SF Symbol for when there's no art (a favorite's own icon).
    var icon: String?
    /// When the app started it; nil for the service's own history.
    var playedAt: Date?

    var id: String { contentId }
}

/// The rules behind the Recents row, kept apart from storage so they can be
/// tested: newest first, one entry per item, at most `limit`.
enum RecentMusic {
    static let limit = 20

    /// `item` moved to the front. A replay that has no art keeps the art
    /// the earlier entry had.
    static func recording(_ item: RecentMusicItem, in list: [RecentMusicItem], limit: Int = limit) -> [RecentMusicItem] {
        var item = item
        if let earlier = list.first(where: { $0.id == item.id }) {
            item.thumbnail = item.thumbnail ?? earlier.thumbnail
            item.icon = item.icon ?? earlier.icon
            item.subtitle = item.subtitle ?? earlier.subtitle
        }
        return Array(([item] + list.filter { $0.id != item.id }).prefix(limit))
    }

    /// What the app started first (albums and playlists, the things you'd
    /// start again), then the service's history for the rest.
    static func merged(local: [RecentMusicItem], service: [RecentMusicItem], limit: Int = limit) -> [RecentMusicItem] {
        var seen = Set<String>()
        return Array((local + service).filter { seen.insert($0.id).inserted }.prefix(limit))
    }

    /// The service's "Recently played" folder in a browse root, if it has
    /// one: Spotify calls it `current_user_recently_played`, Music
    /// Assistant `recently_played`.
    static func historyFolder(in root: HABrowseMediaNode) -> HABrowseMediaNode? {
        root.children?.first { child in
            guard child.canBrowseChildren else { return false }
            let keys = [child.mediaContentId, child.mediaContentType].compactMap { $0?.lowercased() }
            if keys.contains(where: { $0.contains("recently_played") || $0.contains("recent") }) { return true }
            return child.title?.lowercased().contains("recent") == true
        }
    }

    /// The playable entries of a history folder, once each.
    static func items(in folder: HABrowseMediaNode) -> [RecentMusicItem] {
        var seen = Set<String>()
        return (folder.children ?? []).compactMap { item(from: $0) }.filter { seen.insert($0.id).inserted }
    }

    static func item(from node: HABrowseMediaNode, icon: String? = nil) -> RecentMusicItem? {
        guard node.isPlayable, let contentType = node.mediaContentType, let contentId = node.mediaContentId else { return nil }
        return RecentMusicItem(contentType: contentType, contentId: contentId, title: node.displayTitle,
                               subtitle: node.mediaClass.map(className), thumbnail: node.thumbnail, icon: icon)
    }

    static func item(from favorite: MusicFavorite, playedAt: Date = Date()) -> RecentMusicItem {
        RecentMusicItem(contentType: favorite.contentType, contentId: favorite.contentId, title: favorite.displayName,
                        subtitle: className(favorite.contentType), thumbnail: nil, icon: favorite.icon, playedAt: playedAt)
    }

    /// "spotify://playlist" or "playlist" → "Playlist".
    static func className(_ raw: String) -> String {
        let last = raw.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? raw
        return last.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// Recently played music per media account: what was started from the app
/// (kept on the phone) merged with the service's own history (fetched from
/// Home Assistant's media browser when the Music tab opens).
@MainActor
final class RecentMusicStore: ObservableObject {
    static let shared = RecentMusicStore()

    @Published private(set) var local: [String: [RecentMusicItem]] = [:]
    @Published private(set) var service: [String: [RecentMusicItem]] = [:]

    private let defaults: UserDefaults
    private var artworkLookedUp = Set<String>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func items(for account: String) -> [RecentMusicItem] {
        RecentMusic.merged(local: localItems(for: account), service: service[account] ?? [])
    }

    func record(_ item: RecentMusicItem, account: String) {
        var item = item
        item.playedAt = item.playedAt ?? Date()
        save(RecentMusic.recording(item, in: localItems(for: account)), account: account)
    }

    /// Reads the service's history. Silent on failure: the app's own history
    /// still shows.
    func refreshFromService(account: String,
                            browse: (_ type: String?, _ id: String?) async -> HABrowseMediaResult) async {
        let root = await browse(nil, nil)
        guard root.success, let rootNode = root.result,
              let folder = RecentMusic.historyFolder(in: rootNode) else { return }
        let listing: HABrowseMediaNode
        if folder.children != nil {
            listing = folder
        } else {
            let response = await browse(folder.mediaContentType, folder.mediaContentId)
            guard response.success, let node = response.result else { return }
            listing = node
        }
        service[account] = RecentMusic.items(in: listing)
    }

    /// A favorite carries an icon, not art: looks its art up once, after
    /// it's been played. Some items can't be browsed (Spotify's own
    /// playlists); those keep the icon.
    func fillArtwork(for itemId: String, account: String,
                     browse: (_ type: String?, _ id: String?) async -> HABrowseMediaResult) async {
        guard let item = localItems(for: account).first(where: { $0.id == itemId }), item.thumbnail == nil else { return }
        let response = await browse(item.contentType, item.contentId)
        guard let thumbnail = response.result?.thumbnail, !thumbnail.isEmpty else { return }
        let updated = localItems(for: account).map { entry -> RecentMusicItem in
            guard entry.id == itemId else { return entry }
            var entry = entry
            entry.thumbnail = thumbnail
            return entry
        }
        save(updated, account: account)
    }

    /// Entries the app recorded without art (a favorite, or a pick before
    /// art was looked up), each looked up once a launch: one that can't be
    /// browsed keeps its type icon rather than being asked for every time.
    func fillMissingArtwork(account: String,
                            browse: (_ type: String?, _ id: String?) async -> HABrowseMediaResult) async {
        let missing = localItems(for: account).filter { $0.thumbnail == nil && !artworkLookedUp.contains("\(account)|\($0.id)") }
        for item in missing {
            artworkLookedUp.insert("\(account)|\(item.id)")
            await fillArtwork(for: item.id, account: account, browse: browse)
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    func showDemo(_ items: [RecentMusicItem], account: String) {
        local[account] = items
    }
    #endif

    private func localItems(for account: String) -> [RecentMusicItem] {
        // Not cached on read: that would publish a change from inside a
        // view's body. Twenty small entries decode in no time.
        if let cached = local[account] { return cached }
        return defaults.data(forKey: StorageKeys.recentMusic(account: account))
            .flatMap { try? JSONDecoder().decode([RecentMusicItem].self, from: $0) } ?? []
    }

    private func save(_ items: [RecentMusicItem], account: String) {
        local[account] = items
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: StorageKeys.recentMusic(account: account))
        }
    }
}

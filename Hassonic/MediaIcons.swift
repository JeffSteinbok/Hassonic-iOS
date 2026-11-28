import UIKit

/// An SF Symbol for a kind of media, for wherever there's no art: Browse's
/// categories, an item whose art is missing or won't load, a Recents tile.
enum MediaIcon {
    /// Browse's folders are told apart by what they hold: Spotify calls them
    /// all "directory", and only their ids (`current_user_saved_tracks`…)
    /// say which is which. An item goes by its class: its title is
    /// anyone's ("Top 50 Recent Hits" is a playlist, not a history).
    static func symbol(for node: HABrowseMediaNode) -> String {
        let isFolder = node.mediaClass == nil || node.mediaClass == "directory"
            || (node.canBrowseChildren && node.canPlay != true)
        guard isFolder else { return symbol(forClass: node.mediaClass) }
        let keys = [node.mediaContentId, node.mediaContentType, node.title].compactMap { $0?.lowercased() }
        return keywordSymbol(keys) ?? symbol(forClass: node.childrenMediaClass ?? "directory")
    }

    /// For a Recents entry. Its own icon (a favorite's) when that's a real
    /// symbol, else one for its type: never nothing.
    static func symbol(for item: RecentMusicItem) -> String {
        if let icon = item.icon, UIImage(systemName: icon) != nil { return icon }
        return keywordSymbol([item.contentType.lowercased(), item.contentId.lowercased()]) ?? "music.note"
    }

    /// A media class (`playlist`, `artist`…) or content type (`spotify://album`).
    static func symbol(forClass mediaClass: String?) -> String {
        keywordSymbol([mediaClass?.lowercased() ?? ""]) ?? (mediaClass == "directory" ? "folder" : "music.note")
    }

    /// Most specific first: "saved_tracks" is Liked Songs before it's tracks,
    /// "top_artists" a chart before it's artists.
    private static let keywords: [(match: [String], symbol: String)] = [
        (["recently_played", "recent"], "clock"),
        (["saved_tracks", "liked"], "heart"),
        (["top_track"], "chart.bar"),
        (["top_"], "chart.line.uptrend.xyaxis"),
        (["featured"], "star"),
        (["new_release"], "sparkles"),
        (["categor", "genre"], "square.grid.2x2"),
        (["podcast", "show", "episode"], "mic"),
        (["playlist"], "music.note.list"),
        (["artist"], "music.mic"),
        (["album"], "square.stack"),
        (["track", "song"], "music.note"),
        (["radio", "station", "channel"], "dot.radiowaves.left.and.right"),
    ]

    private static func keywordSymbol(_ keys: [String]) -> String? {
        keywords.first { entry in entry.match.contains { word in keys.contains { $0.contains(word) } } }?.symbol
    }

    /// Artists are shown round, like the provider apps do.
    static func isArtist(_ mediaClass: String?) -> Bool {
        mediaClass?.lowercased() == "artist"
    }
}

import Foundation

/// Another media_player entity that actually controls a zone's real-world
/// volume/power/input — e.g. a speaker that plays into a receiver, where the
/// receiver is what has usable volume and source-select controls.
struct ProxyDevice {
    let entityId: String
    /// The value that should be selected via `select_source` on the proxy
    /// for this zone's audio to actually reach it.
    let inputSource: String
}

/// A speaker or multi-speaker group, as curated in the config's `media` section.
/// Home Assistant doesn't expose the individual-vs-group distinction or
/// group membership, so this is maintained by hand.
struct MusicZone: Identifiable {
    enum Kind {
        case speaker
        case group
    }

    let entityId: String
    let displayName: String
    let kind: Kind
    /// Matching entry in the media account entity's `source_list`, if any,
    /// used by `select_source` to cast playback to this zone.
    let sourceName: String?
    /// SF Symbol name shown next to this zone.
    let icon: String
    /// For .group zones: the individual-speaker entity_ids that belong to this group.
    let memberEntityIds: [String]
    /// Manual override to hide a zone regardless of what Home Assistant reports
    /// (e.g. a device that's technically available but no longer actually used).
    let isEnabled: Bool
    /// If set, this zone's own volume is pinned to this level (0.0–1.0) rather
    /// than exposed as user-adjustable — e.g. an Echo feeding a receiver at
    /// fixed line-out volume, where real volume is controlled downstream.
    let defaultVolume: Double?
    /// If set, volume/mute/power/input controls for this zone target this
    /// other device instead of the zone's own entity.
    let proxy: ProxyDevice?

    var id: String { entityId }
}

struct MusicFavorite: Identifiable {
    let displayName: String
    let icon: String
    /// Passed straight through as `media_content_type` / `media_content_id`
    /// on `media_player.play_media` — nothing here is provider-specific.
    let contentType: String
    let contentId: String

    var id: String { contentId }
}

/// One media-provider entity, as curated in the config's `media` section — e.g. a
/// household with separate streaming accounts per person each gets an entry.
/// Speakers/groups are curated per account rather than shared, since which
/// zones are castable can differ by account (Spotify Connect linking is the
/// case this was built for, but nothing below assumes it).
struct MediaAccount: Identifiable {
    let id: String
    let displayName: String
    let entityId: String
    let favorites: [MusicFavorite]
    let zones: [MusicZone]
    /// Entity ids for the Live Activity's zone buttons, in order; nil means
    /// pick automatically. Validated against `zones` when the config loads.
    var liveActivityZoneIds: [String]? = nil
}

/// Runtime model, built from `AppConfiguration.media` by `MusicZones.make`.
/// The config types are the wire format; these are what the views use.
enum MusicZones {
    static func make(from media: MediaConfiguration) -> [MediaAccount] {
        media.accounts.map { account in
            let zones = account.speakers.map {
                MusicZone(entityId: $0.entityId, displayName: $0.displayName, kind: .speaker,
                          sourceName: $0.sourceName, icon: $0.icon, memberEntityIds: [],
                          isEnabled: $0.isEnabled, defaultVolume: $0.defaultVolume,
                          proxy: $0.proxy.map { ProxyDevice(entityId: $0.entityId, inputSource: $0.inputSource) })
            } + account.groups.map {
                MusicZone(entityId: $0.entityId, displayName: $0.displayName, kind: .group,
                          sourceName: $0.sourceName, icon: $0.icon, memberEntityIds: $0.memberEntityIds,
                          isEnabled: $0.isEnabled, defaultVolume: nil, proxy: nil)
            }
            return MediaAccount(
                id: account.id,
                displayName: account.displayName,
                entityId: account.entityId,
                favorites: account.favorites.map {
                    MusicFavorite(displayName: $0.displayName, icon: $0.icon,
                                  contentType: $0.contentType, contentId: $0.contentId)
                },
                zones: zones,
                liveActivityZoneIds: account.liveActivityZones
            )
        }
    }
}

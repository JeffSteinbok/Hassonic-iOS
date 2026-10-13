import ActivityKit
import Foundation

/// The speaker-switcher Live Activity: where a media account is playing,
/// plus one-tap zones and volume. Deliberately not a now-playing surface —
/// no artwork, no transport.
///
/// Compiled into both the app and the widget extension. Everything the
/// extension needs to draw is carried here, so it never reads the app's
/// config, keychain or Home Assistant connection.
struct ZonesActivityAttributes: ActivityAttributes {
    /// A zone as the activity knows it — enough to draw a button and, from
    /// the app process, to act on it without the full media config.
    struct Zone: Codable, Hashable, Identifiable {
        /// The zone's own media_player entity id.
        let id: String
        let name: String
        /// SF Symbol name.
        let icon: String
        /// Entry in the account entity's `source_list` that casts to this zone.
        let sourceName: String
        /// The entities volume −/+ acts on: each member speaker, or its proxy,
        /// minus any pinned at a fixed level. Empty when nothing is adjustable.
        let volumeEntityIds: [String]
    }

    struct ContentState: Codable, Hashable {
        var activeZone: Zone?
        /// Average of the active zone's adjustable volumes; nil when none report one.
        var volume: Double?
        var isPlaying: Bool
        /// Set while a zone tap is waiting on Home Assistant to confirm.
        var pendingZoneId: String?
        /// A one-line problem to show in place of the usual status, e.g. a
        /// zone that isn't on this account.
        var message: String?
        /// The widget asset for the home-screen icon the user picked, so the
        /// activity matches it. Nil means the default mark.
        var appMark: String? = nil
    }

    /// The media account's media_player entity id.
    let accountEntityId: String
    let accountName: String
    /// The zone buttons, in display order. Fixed for the activity's lifetime.
    let quickZones: [Zone]
}

extension ZonesActivityAttributes {
    /// The volume bar's segments: tapping the nth sets n/volumeLevels. A Live
    /// Activity can't host a slider; this is the closest it gets.
    static let volumeLevels = 10

    static let defaultAppMark = "AppMark"

    /// The extension can't ask which icon is set, so the app passes the mark's
    /// asset name: `AppIcon-Clay-Coral` draws `AppMark-Clay-Coral`.
    static func appMark(forAlternateIcon name: String?) -> String? {
        guard let name, name.hasPrefix("AppIcon-") else { return nil }
        return "AppMark-" + name.dropFirst("AppIcon-".count)
    }
}

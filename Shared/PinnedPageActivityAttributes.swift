import ActivityKit
import Foundation

/// A page pinned to the Lock Screen: a way back to it, plus a few of its keys.
/// Tapping it opens hassonic://<pageID>. Started from a button on the page,
/// since an app can't start a Live Activity unless it's open.
struct PinnedPageActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The widget asset for the home-screen icon the user picked. Nil
        /// means the default mark. See `ZonesActivityAttributes.appMark`.
        var appMark: String? = nil
    }

    /// One Home Assistant call a key makes. Carried in the activity so a
    /// press works with the app launched in the background, before its
    /// config has loaded.
    struct Action: Codable, Hashable {
        enum Kind: String, Codable {
            /// `remote.send_command` with `command`.
            case send
            /// `media_player.media_play_pause`.
            case mediaPlayPause
            /// Alternates KEY_PAUSE and KEY_PLAY, for a Samsung TV with no media player.
            case samsungPlayPause
            case runScript
        }

        let kind: Kind
        let entityId: String
        var command: String? = nil
    }

    struct Key: Codable, Hashable, Identifiable {
        let id: String
        let label: String
        /// SF Symbol name.
        let systemImage: String
        /// Empty for the key that opens the page.
        let actions: [Action]
        /// Under the button, e.g. which device a play/pause is for.
        var caption: String? = nil

        var opensPage: Bool { actions.isEmpty }
    }

    let pageID: String
    let title: String
    /// SF Symbol name.
    let systemIcon: String
    /// In display order; empty for a page with nothing worth a key.
    var keys: [Key] = []

    var url: URL? { URL(string: "hassonic://\(pageID)") }
}

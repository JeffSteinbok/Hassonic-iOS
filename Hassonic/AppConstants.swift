import Foundation

/// Names the app shares with Home Assistant and with earlier installs, kept
/// in one place. Changing one strands what an existing install saved under it.
enum AppConstants {
    /// The config file in Home Assistant's `www` folder, `CONFIG_NAME` in
    /// Config/Base.xcconfig. The Dev app (Debug builds) reads its own,
    /// `<name>-dev.yaml`, so trying a change there leaves the release app's
    /// untouched.
    static let configFileName = Bundle.main.object(forInfoDictionaryKey: "ConfigFileName") as? String ?? "hassonic.yaml"
    /// Where Home Assistant serves it, relative to the base URL.
    static let configURLPath = "local/\(configFileName)"
}

/// UserDefaults keys.
enum StorageKeys {
    /// The last config that fetched and validated.
    static let lastKnownGoodConfig = "hassonic.dashboard.lastKnownGoodYAML"
    static let lastSelectedTab = "hassonic.lastSelectedTab"
    /// Server, push token and relay of the last push registration that took,
    /// so a reconnect doesn't register again.
    static let pushRegistration = "hassonic.push.registration"
    /// The media account picked on the Music tab. An old name, kept so the
    /// pick survives an update.
    static let selectedMediaAccount = "selectedSpotifyAccountId"

    /// The zone last picked for an account, for when Home Assistant omits
    /// `source` while paused.
    static func lastPlayOnSource(account entityId: String) -> String {
        "lastPlayOnSourceName_\(entityId)"
    }
}

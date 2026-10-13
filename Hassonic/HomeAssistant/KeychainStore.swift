import Foundation
import Security

enum KeychainStore {
    private static let service = "\(Bundle.main.bundleIdentifier ?? "Hassonic").homeassistant"

    private static func save(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveToken(_ token: String) {
        save(token, account: "accessToken")
    }

    static func loadToken() -> String? {
        load(account: "accessToken")
    }

    static func saveURL(_ url: String) {
        save(url, account: "baseURL")
    }

    static func loadURL() -> String? {
        load(account: "baseURL")
    }

    static func savePushRelayURL(_ url: String) {
        save(url, account: "pushRelayURL")
    }

    static func loadPushRelayURL() -> String? {
        load(account: "pushRelayURL")
    }

    static func saveRefreshToken(_ token: String) {
        save(token, account: "refreshToken")
    }

    static func loadRefreshToken() -> String? {
        load(account: "refreshToken")
    }

    /// Home-network URL, preferred over `baseURL` (external) whenever it's
    /// actually reachable. See ConnectionURLResolver.
    static func saveInternalURL(_ url: String) {
        save(url, account: "internalURL")
    }

    static func loadInternalURL() -> String? {
        load(account: "internalURL")
    }

    /// The Wi-Fi SSID last confirmed to reach the internal URL. Lets
    /// ConnectionURLResolver skip the reachability probe on future
    /// reconnects when back on this network.
    static func saveTrustedSSID(_ ssid: String) {
        save(ssid, account: "trustedSSID")
    }

    static func loadTrustedSSID() -> String? {
        load(account: "trustedSSID")
    }

    /// Removes all stored credentials (access token, refresh token, base URL, push relay URL).
    /// Called on logout to ensure no stale credentials remain.
    static func deleteAll() {
        let accounts = ["accessToken", "refreshToken", "baseURL", "pushRelayURL", "internalURL", "trustedSSID"]
        for account in accounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}

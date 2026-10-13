import Foundation

/// Brings up a Home Assistant connection from nothing but the saved
/// credentials. The app's connection screen and the CarPlay scene are
/// independent entry points into the same process — either can be the first
/// one on screen — so both start from here rather than each reimplementing
/// "resolve internal vs. external, then connect".
enum HAConnectionBootstrapper {
    @MainActor
    static func connectUsingSavedCredentials(
        client: HAWebSocketClient,
        externalURLString: String? = KeychainStore.loadURL(),
        internalURLString: String? = KeychainStore.loadInternalURL(),
        accessToken: String? = KeychainStore.loadToken()
    ) async {
        guard !isBusyOrConnected(client.connectionState),
              let externalURLString, !externalURLString.isEmpty,
              let accessToken, !accessToken.isEmpty else { return }

        let resolvedURLString = await ConnectionURLResolver.resolve(
            externalURLString: externalURLString,
            internalURLString: internalURLString ?? ""
        )
        guard let url = URL(string: resolvedURLString) else { return }
        client.connect(baseURL: url, accessToken: accessToken)
    }

    static func isBusyOrConnected(_ state: HAConnectionState) -> Bool {
        switch state {
        case .connecting, .authenticating, .connected: return true
        case .disconnected, .failed: return false
        }
    }
}

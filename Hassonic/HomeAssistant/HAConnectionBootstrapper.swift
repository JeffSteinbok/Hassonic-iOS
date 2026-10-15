import Foundation

/// Brings up a Home Assistant connection from nothing but the saved
/// credentials: resolve the internal or external URL, then connect.
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

    /// Work that starts outside the app's screens (a Live Activity button,
    /// Siri) can arrive with the app freshly launched in the background, with
    /// no socket and no entities yet. Connects from the saved credentials and
    /// waits up to ten seconds for `entityId` to load.
    @MainActor
    static func connectAndWait(client: HAWebSocketClient, for entityId: String) async -> Bool {
        func ready() -> Bool { client.connectionState == .connected && client.entity(entityId) != nil }
        if ready() { return true }

        if client.tokenRefresher == nil {
            let oauthClient = HAOAuthClient()
            client.tokenRefresher = { await oauthClient.refreshUsingSavedToken(baseURL: $0) }
        }
        await connectUsingSavedCredentials(client: client)

        for _ in 0..<100 {
            if ready() { return true }
            if case .failed = client.connectionState { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Signs a simulator in without the OAuth flow, for screenshots and UI
    /// checks: launch with HASSONIC_HA_URL and HASSONIC_HA_TOKEN (a long-lived
    /// access token) in the environment, e.g. through simctl's SIMCTL_CHILD_
    /// prefix. HASSONIC_OPEN_URL, also read at launch, opens a page.
    /// Debug simulator builds only.
    static func saveCredentialsFromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let url = environment["HASSONIC_HA_URL"], !url.isEmpty,
              let token = environment["HASSONIC_HA_TOKEN"], !token.isEmpty else { return }
        KeychainStore.saveURL(url)
        KeychainStore.saveToken(token)
    }
    #endif

    static func isBusyOrConnected(_ state: HAConnectionState) -> Bool {
        switch state {
        case .connecting, .authenticating, .connected: return true
        case .disconnected, .failed: return false
        }
    }
}

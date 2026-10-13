import Foundation

/// What the app's root shows. Connection drops are routine (backgrounding,
/// Wi-Fi changes, a server restart) and the client retries them on its own,
/// so the failure screen is held back until a retry can't happen or the
/// connection has been down long enough that waiting isn't helping.
enum AppRootPhase: Equatable {
    /// No saved connection: first-run setup.
    case welcome
    /// Saved connection, not up yet this session.
    case connecting
    case connected
    case failed(String)

    /// How long to wait on a connection before showing the failure screen.
    static let connectTimeout: Duration = .seconds(15)

    static func resolve(
        hasSavedConnection: Bool,
        connectionState: HAConnectionState,
        willRetry: Bool,
        isStarting: Bool,
        hasConnected: Bool,
        isOverdue: Bool
    ) -> Self {
        if connectionState == .connected { return .connected }
        guard hasSavedConnection else { return .welcome }

        switch connectionState {
        case .failed(let message) where !willRetry:
            return .failed(message)
        case .disconnected where !isStarting:
            return .failed("Not connected to Home Assistant.")
        default:
            break
        }
        if isOverdue {
            if case .failed(let message) = connectionState { return .failed(message) }
            return .failed("Home Assistant isn't responding.")
        }
        // Once the tabs are up, a reconnect keeps them up rather than
        // swapping the whole screen out for a few seconds.
        return hasConnected ? .connected : .connecting
    }
}

enum AppRootState {
    static var hasSavedConnection: Bool {
        ConnectionLandingState.initial(
            savedURL: KeychainStore.loadURL(),
            savedToken: KeychainStore.loadToken()
        ) == .connection
    }
}

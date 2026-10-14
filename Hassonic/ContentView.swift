import SwiftUI

enum ConnectionLandingState: Equatable {
    case loading
    case welcome
    case connection

    static func initial(savedURL: String?, savedToken: String?) -> Self {
        guard let savedURL,
              !savedURL.isEmpty,
              let savedToken,
              !savedToken.isEmpty else {
            return .welcome
        }
        return .connection
    }
}

struct ContentView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var haClient: HAWebSocketClient
    @EnvironmentObject private var dashboardLoader: AppConfigurationLoader
    @State private var landingState = ConnectionLandingState.loading
    @State private var baseURLString: String = ""
    @State private var internalURLString: String = ""
    @State private var pushRelayURLString: String = ""
    @State private var isAuthenticating = false
    @State private var isConfirmingSignOut = false
    @State private var hasSavedConnection = false
    @StateObject private var oauthClient = HAOAuthClient()

    var body: some View {
        NavigationStack {
            Group {
                switch landingState {
                case .loading:
                    launchPlaceholder
                case .welcome:
                    welcomeView
                case .connection:
                    connectionView
                }
            }
            .onAppear(perform: loadSavedConnection)
        }
    }

    private var launchPlaceholder: some View {
        ZStack {
            Color("LaunchBackground")
                .ignoresSafeArea()
            Image("WelcomeMark")
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)
                .accessibilityHidden(true)
        }
    }

    private var welcomeView: some View {
        ZStack {
            Color("LaunchBackground")
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 48)

                    Image("WelcomeMark")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220)
                        .accessibilityHidden(true)

                    VStack(spacing: 12) {
                        Text("Welcome to \(AppIdentity.name)")
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)

                        Text("A focused, native way to control your Home Assistant home.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Spacer(minLength: 24)

                    Button {
                        withAnimation(.easeInOut) {
                            landingState = .connection
                        }
                    } label: {
                        Text("Get Started")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityHint("Opens Home Assistant connection setup")
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 28)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, minHeight: 620)
            }
        }
    }

    private var connectionView: some View {
        List {
            Section("Connect to Home Assistant") {
                TextField("Home Assistant URL", text: $baseURLString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                if isBusyOrConnected {
                    Button("Disconnect") {
                        haClient.disconnect()
                    }
                } else {
                    Button {
                        Task { await loginWithOAuth() }
                    } label: {
                        if isAuthenticating {
                            HStack {
                                ProgressView()
                                    .padding(.trailing, 4)
                                Text("Authenticating…")
                            }
                        } else {
                            Text("Log in with Home Assistant")
                        }
                    }
                    .disabled(baseURLString.isEmpty || isAuthenticating)
                }

                HStack {
                    Text("Status")
                    Spacer()
                    Text(statusText)
                        .foregroundStyle(statusColor)
                }
            }

            Section("Optional") {
                DisclosureGroup("Advanced Connection Settings") {
                    TextField("Internal URL", text: $internalURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    Text("Used on your home network when available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextField("Push Relay URL", text: $pushRelayURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    Text("Only needed when configuring custom push notifications.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if haClient.connectionState == .connected {
                Section("Dashboard Configuration") {
                    LabeledContent("Source", value: dashboardSourceText)

                    Button {
                        Task {
                            await dashboardLoader.refresh(
                                baseURLString: haClient.baseURLString,
                                accessToken: haClient.accessToken
                            )
                        }
                    } label: {
                        if dashboardLoader.isRefreshing {
                            HStack {
                                ProgressView()
                                Text("Reloading Dashboard")
                            }
                        } else {
                            Text("Reload Dashboard")
                        }
                    }
                    .disabled(dashboardLoader.isRefreshing)

                    if let errorMessage = dashboardLoader.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Appearance") {
                NavigationLink("App Icon") {
                    AppIconPickerView()
                }
            }

            if hasSavedConnection {
                Section {
                    Button("Sign Out", role: .destructive) {
                        isConfirmingSignOut = true
                    }
                } footer: {
                    Text("Removes this Home Assistant connection and its saved credentials from this device.")
                }
            }

            BuildDiagnosticsSection()
        }
        .navigationTitle(AppIdentity.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Sign out of Home Assistant?",
            isPresented: $isConfirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive, action: signOut)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will need to connect and authenticate again.")
        }
    }

    private func loadSavedConnection() {
        guard landingState == .loading else { return }

        let savedURL = KeychainStore.loadURL()
        let savedToken = KeychainStore.loadToken()
        if let savedURL {
            baseURLString = savedURL
        }
        if let savedInternalURL = KeychainStore.loadInternalURL() {
            internalURLString = savedInternalURL
        }
        if let savedPushRelayURL = KeychainStore.loadPushRelayURL() {
            pushRelayURLString = savedPushRelayURL
        }

        landingState = .initial(savedURL: savedURL, savedToken: savedToken)
        hasSavedConnection = landingState == .connection
        guard landingState == .connection else { return }
        Task { await autoConnectIfPossible() }
    }

    private var isBusyOrConnected: Bool {
        HAConnectionBootstrapper.isBusyOrConnected(haClient.connectionState)
    }

    private var statusText: String {
        switch haClient.connectionState {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .authenticating: return "Authenticating…"
        case .connected: return "Connected"
        case .failed(let message): return message
        }
    }

    private var statusColor: Color {
        switch haClient.connectionState {
        case .connected: return .green
        case .failed: return .red
        case .disconnected: return .secondary
        case .connecting, .authenticating: return .orange
        }
    }

    private var dashboardSourceText: String {
        switch dashboardLoader.source {
        case .bundled: return "Bundled Default"
        case .cache: return "Last Known Good"
        case .remote: return "Home Assistant"
        case .debugOverride: return "Debug Override File"
        }
    }

    private func resolvedConnectionURL() async -> URL? {
        let resolvedURLString = await ConnectionURLResolver.resolve(
            externalURLString: baseURLString,
            internalURLString: internalURLString
        )
        return URL(string: resolvedURLString)
    }

    private func autoConnectIfPossible() async {
        await HAConnectionBootstrapper.connectUsingSavedCredentials(
            client: haClient,
            externalURLString: baseURLString,
            internalURLString: internalURLString
        )
    }

    private func loginWithOAuth() async {
        isAuthenticating = true
        defer { isAuthenticating = false }
        guard let url = await resolvedConnectionURL() else { return }

        // Try a silent refresh first, but only against the server the saved
        // refresh token came from: it never goes to a newly typed address.
        if baseURLString == KeychainStore.loadURL(),
           case .refreshed(let newAccessToken) = await oauthClient.refreshUsingSavedToken(baseURL: url) {
            saveConnectionSettings()
            KeychainStore.saveToken(newAccessToken)
            haClient.connect(baseURL: url, accessToken: newAccessToken)
            return
        }

        // Fall through to full OAuth login in the browser. The external URL
        // is always used for the login flow itself, since that's the one
        // guaranteed reachable from wherever the browser redirect lands.
        guard let externalURL = URL(string: baseURLString),
              let tokens = await oauthClient.login(baseURL: externalURL) else { return }
        saveConnectionSettings()
        KeychainStore.saveToken(tokens.accessToken)
        if let refreshToken = tokens.refreshToken {
            KeychainStore.saveRefreshToken(refreshToken)
        }
        haClient.connect(baseURL: url, accessToken: tokens.accessToken)
    }

    private func saveConnectionSettings() {
        KeychainStore.saveURL(baseURLString)
        KeychainStore.saveInternalURL(internalURLString)
        KeychainStore.savePushRelayURL(pushRelayURLString)
        hasSavedConnection = true
    }

    private func signOut() {
        haClient.disconnect()
        KeychainStore.deleteAll()
        baseURLString = ""
        internalURLString = ""
        pushRelayURLString = ""
        hasSavedConnection = false
        withAnimation(.easeInOut) {
            landingState = .welcome
        }
        dismiss()
    }
}

private struct BuildDiagnosticsSection: View {
    private let build = BuildInformation.current

    var body: some View {
        Section("Build") {
            LabeledContent("Version", value: build.versionAndBuild)
            LabeledContent("Revision", value: build.revision)
            LabeledContent("Built", value: build.timestamp)
            LabeledContent("Configuration", value: build.configuration)
        }
        .textSelection(.enabled)
    }
}

#Preview {
    ContentView()
        .environmentObject(HAWebSocketClient())
        .environmentObject(AppConfigurationLoader())
}

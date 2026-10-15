import Foundation

enum DashboardConfigurationSource: Equatable {
    case bundled
    case cache
    case remote
    /// Only ever produced by a debug build — see `debugOverrideYAML()`.
    case debugOverride
}

@MainActor
final class AppConfigurationLoader: ObservableObject {
    @Published private(set) var appConfiguration: AppConfiguration
    /// The dashboard slice, for views that only care about pages.
    var configuration: DashboardConfiguration { appConfiguration.dashboard }
    /// Media accounts in their runtime shape.
    var mediaAccounts: [MediaAccount] { MusicZones.make(from: appConfiguration.media) }
    var speakerClaim: SpeakerClaimConfig? { appConfiguration.speakerClaim }
    var mediaProvider: MediaProviderConfiguration? { appConfiguration.media.provider }
    @Published private(set) var source: DashboardConfigurationSource
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false

    private static let cacheKey = StorageKeys.lastKnownGoodConfig

    private let defaults: UserDefaults
    /// Nil in the app: each refresh gets a fresh ephemeral session. On
    /// resume, a connection pooled from before the app was suspended can
    /// fail its TLS handshake (-1200 / -9816) several times in a row even
    /// while the WebSocket to the same host reconnects fine.
    private let session: URLSession?
    /// Waits between attempts when a fetch fails at the network level. The
    /// fetch runs the moment the connection comes up, which is often while the
    /// phone is still waking or changing networks, and one dropped handshake
    /// there used to leave "not updated" on screen until the next reconnect.
    var networkRetryDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(8)]
    /// Only the app's own loader looks for the debug override file; tests
    /// share the app container and must not pick up a developer's override.
    private let usesDebugOverride: Bool
    /// Retained so a cleared override can fall back the way a fresh launch
    /// would. Nil for the loaders tests build directly.
    private let bundledYAML: String?

#if DEBUG
    /// The override contents already on screen, so the repeated events a single
    /// save produces do not reparse and republish the same dashboard.
    private var appliedOverrideYAML: String?
    private var overrideWatcher: DashboardOverrideWatcher?
#endif

    init(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        session: URLSession? = nil
    ) {
        self.defaults = defaults
        self.session = session
        self.usesDebugOverride = true

        guard let bundledURL = bundle.url(forResource: "Config", withExtension: "yaml"),
              let bundledYAML = try? String(contentsOf: bundledURL, encoding: .utf8) else {
            preconditionFailure("Config.yaml is missing from the app bundle.")
        }
        self.bundledYAML = bundledYAML

        var overrideError: String?
        var override: AppConfiguration?
        if let overrideYAML = Self.debugOverrideYAML() {
            do {
                override = try AppConfigurationParser.parse(overrideYAML)
#if DEBUG
                appliedOverrideYAML = overrideYAML
#endif
            } catch {
                overrideError = Self.debugOverrideErrorMessage(error)
            }
        }

        if let override {
            appConfiguration = override
            source = .debugOverride
        } else {
            let cachedYAML = defaults.string(forKey: Self.cacheKey)
            do {
                let initial = try Self.selectInitialConfiguration(
                    cachedYAML: cachedYAML,
                    bundledYAML: bundledYAML
                )
                appConfiguration = initial.configuration
                source = initial.source
                errorMessage = overrideError ?? initial.cacheError
            } catch {
                preconditionFailure("Bundled Config.yaml is invalid: \(error.localizedDescription)")
            }
        }

        startWatchingDebugOverride()
    }

    init(
        configuration: AppConfiguration,
        source: DashboardConfigurationSource = .bundled,
        defaults: UserDefaults,
        session: URLSession,
        usesDebugOverride: Bool = false,
        bundledYAML: String? = nil
    ) {
        self.appConfiguration = configuration
        self.source = source
        self.defaults = defaults
        self.session = session
        self.usesDebugOverride = usesDebugOverride
        self.bundledYAML = bundledYAML
    }

    func refresh(baseURLString: String, accessToken: String?) async {
        // A debug override pins the dashboard, so a Home Assistant fetch would
        // only stomp on what the developer just dropped in.
        if applyDebugOverride() {
            return
        }

        guard let baseURL = URL(string: baseURLString), baseURL.scheme != nil else {
            errorMessage = "Cannot load dashboard configuration because the Home Assistant URL is invalid."
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        var request = URLRequest(
            url: baseURL.appendingPathComponent(AppConstants.configURLPath),
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await fetchRetryingTransientFailures(request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw DashboardRemoteLoadError.httpStatus(status)
            }
            guard let yaml = String(data: data, encoding: .utf8) else {
                throw DashboardRemoteLoadError.invalidEncoding
            }
            try Self.rejectNonYAMLBody(yaml)

            let parsed = try AppConfigurationParser.parse(yaml)
            defaults.set(yaml, forKey: Self.cacheKey)
            appConfiguration = parsed
            source = .remote
            errorMessage = nil
        } catch is CancellationError {
            // Superseded (a pull-to-refresh let go early, a newer refresh):
            // nothing went wrong, so there's nothing to report.
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            Log.config.note("refresh of \(request.url?.absoluteString ?? "?") failed — \(error)")
            // A network blip leaves the last good config on screen, which is
            // exactly what a successful fetch of an unchanged file would show,
            // so it's not worth a banner. The next foreground or pull retries.
            if let urlError = error as? URLError,
               Self.transientErrorCodes.contains(urlError.code),
               source != .bundled {
                return
            }
            errorMessage = "Dashboard config was not updated: \(error.localizedDescription)"
        }
    }

    /// Network-level failures that a moment later usually succeed. Anything
    /// else (a 404, a parse error, bad credentials) won't fix itself, so it
    /// fails straight away.
    private static let transientErrorCodes: Set<URLError.Code> = [
        .secureConnectionFailed, .networkConnectionLost, .timedOut,
        .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
    ]

    private func fetchRetryingTransientFailures(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var delays = networkRetryDelays[...]
        while true {
            let session = self.session ?? URLSession(configuration: .ephemeral)
            defer { if self.session == nil { session.finishTasksAndInvalidate() } }
            do {
                return try await session.data(for: request)
            } catch let error as URLError where Self.transientErrorCodes.contains(error.code) {
                guard let delay = delays.popFirst() else { throw error }
                try await Task.sleep(for: delay)
            }
        }
    }

    /// Debug builds read `Documents/config-override.yaml` from the app
    /// container instead of Home Assistant, so `scripts/inject_config.py`
    /// can push a dashboard into a simulator and have it stick across
    /// reconnects. Release builds always return nil.
    static func debugOverrideYAML() -> String? {
#if DEBUG
        guard let documents = documentsDirectory(),
              let yaml = try? String(
                  contentsOf: documents.appendingPathComponent("config-override.yaml"),
                  encoding: .utf8
              ) else {
            return nil
        }
        return yaml
#else
        return nil
#endif
    }

    private static func debugOverrideErrorMessage(_ error: Error) -> String {
        "Debug dashboard override is invalid: \(error.localizedDescription)"
    }

    /// Applies the dashboard injected by `scripts/inject_config.py`, and
    /// reports whether an override is pinning the dashboard — `refresh` skips
    /// its Home Assistant fetch when one is, so a reconnect cannot stomp what
    /// was just injected. Release builds have no override and always say no.
    @discardableResult
    func applyDebugOverride() -> Bool {
#if DEBUG
        guard usesDebugOverride else { return false }

        guard let overrideYAML = Self.debugOverrideYAML() else {
            if appliedOverrideYAML != nil {
                appliedOverrideYAML = nil
                fallBackFromClearedOverride()
            }
            return false
        }

        // A single save reaches the watcher as several directory events, and
        // the temporary file the inject script replaces through is one of them.
        guard overrideYAML != appliedOverrideYAML else { return true }

        do {
            appConfiguration = try AppConfigurationParser.parse(overrideYAML)
            source = .debugOverride
            errorMessage = nil
            appliedOverrideYAML = overrideYAML
        } catch {
            // Leave the dashboard that is on screen alone — the banner names
            // the problem, and the next save can fix it.
            errorMessage = Self.debugOverrideErrorMessage(error)
        }
        return true
#else
        return false
#endif
    }

#if DEBUG
    private func startWatchingDebugOverride() {
        guard usesDebugOverride, let documents = Self.documentsDirectory() else { return }
        overrideWatcher = DashboardOverrideWatcher(directoryURL: documents) { [weak self] in
            Task { @MainActor in
                self?.applyDebugOverride()
            }
        }
    }

    /// A cleared override leaves the dashboard resolved the way a fresh launch
    /// would resolve it, rather than stranding the injected one on screen.
    private func fallBackFromClearedOverride() {
        guard let bundledYAML,
              let initial = try? Self.selectInitialConfiguration(
                  cachedYAML: defaults.string(forKey: Self.cacheKey),
                  bundledYAML: bundledYAML
              ) else {
            return
        }
        appConfiguration = initial.configuration
        source = initial.source
        errorMessage = initial.cacheError
    }

    private static func documentsDirectory() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
#else
    private func startWatchingDebugOverride() {}
#endif

    /// Home Assistant answers 200 with a frontend HTML page for paths it has
    /// not registered yet, which happens for `/local/*` while it is still
    /// starting. Naming that beats the decoder's "not a mapping" complaint.
    static func rejectNonYAMLBody(_ yaml: String) throws {
        let trimmed = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw DashboardRemoteLoadError.emptyBody
        }
        if trimmed.hasPrefix("<") {
            throw DashboardRemoteLoadError.htmlBody
        }
    }

    /// What a fresh launch starts with, the last config that loaded or else
    /// the bundled one, for Siri and Shortcuts running without the app's
    /// screens.
    static func launchConfiguration(bundle: Bundle = .main, defaults: UserDefaults = .standard) -> AppConfiguration? {
        guard let url = bundle.url(forResource: "Config", withExtension: "yaml"),
              let bundledYAML = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try? selectInitialConfiguration(cachedYAML: defaults.string(forKey: cacheKey), bundledYAML: bundledYAML).configuration
    }

    static func selectInitialConfiguration(
        cachedYAML: String?,
        bundledYAML: String
    ) throws -> (
        configuration: AppConfiguration,
        source: DashboardConfigurationSource,
        cacheError: String?
    ) {
        if let cachedYAML {
            do {
                return (try AppConfigurationParser.parse(cachedYAML), .cache, nil)
            } catch {
                let bundled = try AppConfigurationParser.parse(bundledYAML)
                return (
                    bundled,
                    .bundled,
                    "Saved dashboard config was invalid; using the bundled dashboard. \(error.localizedDescription)"
                )
            }
        }

        return (try AppConfigurationParser.parse(bundledYAML), .bundled, nil)
    }
}

enum DashboardRemoteLoadError: LocalizedError, Equatable {
    case httpStatus(Int)
    case invalidEncoding
    case emptyBody
    case htmlBody

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status):
            return status == 0
                ? "Home Assistant returned an invalid response."
                : "Home Assistant returned HTTP \(status)."
        case .invalidEncoding:
            return "The dashboard YAML is not valid UTF-8."
        case .emptyBody:
            return "Home Assistant returned an empty dashboard file."
        case .htmlBody:
            return "Home Assistant returned a web page instead of the dashboard YAML. "
                + "It may still be starting up, or \(AppConstants.configFileName) may not be in its www folder."
        }
    }
}

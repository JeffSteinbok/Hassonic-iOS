import SwiftUI
import UserNotifications
import UIKit
import FirebaseCore
import FirebaseMessaging

@MainActor
final class PushNotificationCoordinator: NSObject, ObservableObject {
    @Published private(set) var pushToken: String?
    private lazy var registrar = HAMobileAppRegistrar()

    func requestAuthorizationAndRegisterForRemoteNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    // Called by the AppDelegate once Firebase has exchanged the APNs token for an FCM registration token.
    func updateFCMToken(_ token: String) {
        pushToken = token
    }

    func registerWithHomeAssistantIfPossible(baseURLString: String, accessToken: String?, connectionState: HAConnectionState) {
        guard connectionState == .connected,
              let token = accessToken,
              let pushToken,
              !pushToken.isEmpty,
              let baseURL = URL(string: baseURLString),
              let pushRelayURL = KeychainStore.loadPushRelayURL(),
              !pushRelayURL.isEmpty else { return }

        // Once per server, token and relay: each connect would otherwise
        // register again.
        let registration = [baseURL.absoluteString, pushToken, pushRelayURL].joined(separator: "|")
        guard UserDefaults.standard.string(forKey: StorageKeys.pushRegistration) != registration else { return }

        Task {
            do {
                try await registrar.register(baseURL: baseURL, accessToken: token, pushToken: pushToken, pushURL: pushRelayURL)
                UserDefaults.standard.set(registration, forKey: StorageKeys.pushRegistration)
            } catch {
                Log.push.note("Push registration failed: \(error.localizedDescription)")
            }
        }
    }
}

extension PushNotificationCoordinator: MessagingDelegate {
    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        Task { @MainActor in
            self.updateFCMToken(fcmToken)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    var pushCoordinator: PushNotificationCoordinator?
    private(set) var isFirebaseConfigured = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        guard let configuration = FirebaseConfiguration.load() else {
            Log.push.note("Firebase configuration is missing or invalid; push notifications are disabled.")
            return true
        }

        FirebaseApp.configure(options: configuration)
        isFirebaseConfigured = true
        return true
    }

    /// The scene delegate only catches app-icon quick actions; SwiftUI does
    /// everything else.
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard isFirebaseConfigured else { return }
        Messaging.messaging().apnsToken = deviceToken
    }
}

enum NotificationLink {
    static func url(from userInfo: [AnyHashable: Any]) -> URL? {
        guard let value = userInfo["url"] as? String,
              let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              AppRouter.schemes.contains(scheme), url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let url = NotificationLink.url(from: response.notification.request.content.userInfo) {
            Task { @MainActor in PendingLink.shared.url = url }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

enum FirebaseConfiguration {
    static func load(from bundle: Bundle = .main) -> FirebaseOptions? {
        guard let path = bundle.path(forResource: "GoogleService-Info", ofType: "plist"),
              let data = FileManager.default.contents(atPath: path),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              isValid(values) else {
            return nil
        }

        return FirebaseOptions(contentsOfFile: path)
    }

    static func isValid(_ values: [String: Any]) -> Bool {
        let requiredKeys = ["GOOGLE_APP_ID", "GCM_SENDER_ID", "PROJECT_ID", "API_KEY"]
        guard requiredKeys.allSatisfy({
            guard let value = values[$0] as? String else { return false }
            return !value.isEmpty && value != "REPLACE_ME"
        }),
        let appID = values["GOOGLE_APP_ID"] as? String,
        appID.range(of: #"^1:[0-9]+:ios:[0-9a-fA-F]+$"#, options: .regularExpression) != nil,
        let senderID = values["GCM_SENDER_ID"] as? String,
        senderID.allSatisfy(\.isNumber) else {
            return false
        }

        return true
    }
}

@main
struct HassonicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var haClient = HAWebSocketClient.shared
    @StateObject private var router = AppRouter(lastTabStore: .standard)
    @StateObject private var dashboardLoader = AppConfigurationLoader()
    @StateObject private var pushCoordinator = PushNotificationCoordinator()
    @StateObject private var oauthClient = HAOAuthClient()
    @StateObject private var assistant = AssistantChatModel()
    @State private var pendingLinkURL: URL?
    @State private var hasRefreshedConfiguration = false
    @State private var wasBackgrounded = false
    @State private var hasSavedConnection = AppRootState.hasSavedConnection
    /// True from launch until the first connection attempt is under way, so
    /// the brief .disconnected before it isn't mistaken for a failure.
    @State private var isStartingConnection = true
    @State private var hasConnected = false
    @State private var isConnectionOverdue = false
    @State private var overdueTimer: Task<Void, Never>?
    /// Same key MusicZonesView's account switcher writes.
    @AppStorage(StorageKeys.selectedMediaAccount) private var selectedMediaAccountId: String = ""

    var body: some Scene {
        WindowGroup {
            rootView
            .sheet(item: $router.presentedSheet) { sheet in
                switch sheet {
                case .settings: ContentView()
                case .about: AboutView()
                case .assistant:
                    if let configuration = dashboardLoader.appConfiguration.assistant {
                        AssistantView(configuration: configuration)
                    }
                }
            }
            .environmentObject(haClient)
            .environmentObject(router)
            .environmentObject(dashboardLoader)
            .environmentObject(assistant)
            .onOpenURL { url in
                pendingLinkURL = url
                routePendingLink()
            }
            // A Shortcuts action or app-icon quick action. A turn later, so a
            // cold launch has its pages set (onAppear) before it's handled.
            .onReceive(PendingLink.shared.$url.compactMap { $0 }) { url in
                PendingLink.shared.url = nil
                pendingLinkURL = url
                routePendingLink()
            }
            .onAppear {
                appDelegate.pushCoordinator = pushCoordinator
                router.setDashboardPages(dashboardLoader.configuration.pages)
                router.setAssistantEnabled(dashboardLoader.appConfiguration.assistant != nil)
                PageShortcuts.update(for: dashboardLoader.configuration.pages)
                // Token refresh has nothing to do with push, so it's set up
                // whether or not Firebase is.
                let oauthClient = oauthClient
                haClient.tokenRefresher = { [weak oauthClient] baseURL in
                    await oauthClient?.refreshUsingSavedToken(baseURL: baseURL) ?? .rejected
                }
                Task { await startConnection() }
                guard appDelegate.isFirebaseConfigured else { return }
                Messaging.messaging().delegate = pushCoordinator
                pushCoordinator.requestAuthorizationAndRegisterForRemoteNotifications()
            }
            .onChange(of: haClient.connectionState) { _, newState in
                pushCoordinator.registerWithHomeAssistantIfPossible(
                    baseURLString: haClient.baseURLString,
                    accessToken: haClient.accessToken,
                    connectionState: newState
                )
                // Settings saves or deletes the connection, then connects or
                // disconnects, so a state change is the moment to re-check.
                hasSavedConnection = AppRootState.hasSavedConnection
                if !hasSavedConnection {
                    assistant.pause()
                    hasRefreshedConfiguration = false
                    // Signed out: the next sign-in starts over from the splash.
                    hasConnected = false
                }
                guard newState == .connected else {
                    startOverdueTimer()
                    return
                }
                overdueTimer?.cancel()
                overdueTimer = nil
                isConnectionOverdue = false
                if !hasConnected {
                    hasConnected = true
                    router.selectConnectedLandingPage(from: dashboardLoader.configuration.pages)
                    #if DEBUG && targetEnvironment(simulator)
                    // HASSONIC_OPEN_URL: a hassonic:// link to follow once
                    // connected, without iOS's "Open in…?" prompt.
                    if let link = ProcessInfo.processInfo.environment["HASSONIC_OPEN_URL"].flatMap(URL.init(string:)) {
                        router.handle(url: link)
                    }
                    #endif
                }
                Task {
                    await dashboardLoader.refresh(
                        baseURLString: haClient.baseURLString,
                        accessToken: haClient.accessToken
                    )
                    hasRefreshedConfiguration = true
                    routePendingLink()
                }
            }
            .onChange(of: dashboardLoader.configuration) { _, configuration in
                router.setDashboardPages(configuration.pages)
                PageShortcuts.update(for: configuration.pages)
            }
            .onChange(of: dashboardLoader.appConfiguration.assistant) { _, configuration in
                router.setAssistantEnabled(configuration != nil)
                if configuration == nil { assistant.pause() }
                routePendingLink()
            }
            .onReceive(haClient.$entities) { _ in syncLiveActivity() }
            .onChange(of: dashboardLoader.appConfiguration.media) { _, _ in
                syncLiveActivity()
                // Siri's speaker and favorite names.
                HassonicShortcuts.updateAppShortcutParameters()
            }
            .onChange(of: selectedMediaAccountId) { _, _ in syncLiveActivity() }
            .onChange(of: pushCoordinator.pushToken) { _, _ in
                pushCoordinator.registerWithHomeAssistantIfPossible(
                    baseURLString: haClient.baseURLString,
                    accessToken: haClient.accessToken,
                    connectionState: haClient.connectionState
                )
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .background:
                    assistant.pause()
                    wasBackgrounded = true
                case .active where wasBackgrounded:
                    wasBackgrounded = false
                    Task {
                        await reconnectResolvingNetwork()
                        // Pick up config edits made while away, and clear a
                        // failure left over from a flaky moment.
                        guard haClient.connectionState == .connected else { return }
                        await dashboardLoader.refresh(
                            baseURLString: haClient.baseURLString,
                            accessToken: haClient.accessToken
                        )
                    }
                    // A Live Activity can only start while the app is in the
                    // foreground, so playback that began while it wasn't gets
                    // its chance here.
                    syncLiveActivity()
                default:
                    break
                }
            }
        }
    }

    private var rootPhase: AppRootPhase {
        AppRootPhase.resolve(
            hasSavedConnection: hasSavedConnection,
            connectionState: haClient.connectionState,
            willRetry: haClient.willRetry,
            isStarting: isStartingConnection,
            hasConnected: hasConnected,
            isOverdue: isConnectionOverdue
        )
    }

    @ViewBuilder
    private var rootView: some View {
        switch rootPhase {
        case .welcome:
            ContentView()
        case .connecting:
            SplashView()
        case .failed(let message):
            ConnectionFailedView(
                message: message,
                onRetry: { Task { await startConnection() } },
                onSettings: { router.presentedSheet = .settings }
            )
        case .connected:
            TabView(selection: $router.selectedTab) {
                MusicZonesView()
                    .tabItem { Label("Music", systemImage: "music.note") }
                    .tag(AppTab.music)
                let pages = dashboardLoader.configuration.pages.filter { !$0.isRoom }
                let rooms = dashboardLoader.configuration.pages.filter(\.isRoom)
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    DashboardPageView(
                        page: page,
                        isInMoreTab: AppTab.isInMore(tabIndex: index + 1, tabCount: pages.count + 1),
                        rooms: index == 0 ? rooms : []
                    )
                        .tabItem { Label(page.title, systemImage: page.systemIcon) }
                        .tag(AppTab.dashboard(page.id))
                }
            }
        }
    }

    private func routePendingLink() {
        guard hasConnected, hasRefreshedConfiguration, let url = pendingLinkURL else { return }
        router.setAssistantEnabled(dashboardLoader.appConfiguration.assistant != nil)
        pendingLinkURL = nil
        router.handle(url: url)
    }

    /// Connects with the saved credentials, at launch and from Try Again.
    private func startConnection() async {
        isConnectionOverdue = false
        overdueTimer?.cancel()
        overdueTimer = nil
        isStartingConnection = true
        defer { isStartingConnection = false }
        #if DEBUG && targetEnvironment(simulator)
        if let demo = DemoMode.entities() {
            hasSavedConnection = true
            haClient.showDemo(entities: demo)
            return
        }
        HAConnectionBootstrapper.saveCredentialsFromEnvironment()
        #endif
        hasSavedConnection = AppRootState.hasSavedConnection
        guard hasSavedConnection else { return }
        startOverdueTimer()
        await HAConnectionBootstrapper.connectUsingSavedCredentials(client: haClient)
    }

    /// Runs once per outage: the client flips between .failed and
    /// .connecting while it retries, and that mustn't restart the clock.
    private func startOverdueTimer() {
        guard overdueTimer == nil, !isConnectionOverdue else { return }
        overdueTimer = Task {
            try? await Task.sleep(for: AppRootPhase.connectTimeout)
            guard !Task.isCancelled else { return }
            overdueTimer = nil
            if haClient.connectionState != .connected {
                isConnectionOverdue = true
            }
        }
    }

    private func syncLiveActivity() {
        let accounts = dashboardLoader.mediaAccounts
        let account = accounts.first { $0.id == selectedMediaAccountId } ?? accounts.first
        ZonesLiveActivityController.shared.sync(account: account)
    }

    /// The Wi-Fi network can change while backgrounded (left home, came
    /// back), so re-resolve internal vs. external before just resuming the
    /// same connection — if it picks a different URL than we're currently
    /// on, reconnect fresh rather than retrying the now-stale one.
    private func reconnectResolvingNetwork() async {
        guard let externalURLString = KeychainStore.loadURL(), !externalURLString.isEmpty else {
            haClient.reconnectAfterForeground()
            return
        }
        let resolvedURLString = await ConnectionURLResolver.resolve(
            externalURLString: externalURLString,
            internalURLString: KeychainStore.loadInternalURL() ?? ""
        )

        guard resolvedURLString != haClient.baseURLString,
              let resolvedURL = URL(string: resolvedURLString),
              let token = haClient.accessToken else {
            haClient.reconnectAfterForeground()
            return
        }
        haClient.connect(baseURL: resolvedURL, accessToken: token)
    }
}

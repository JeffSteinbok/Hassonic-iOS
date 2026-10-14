import Foundation
import Combine

enum HAConnectionState: Equatable {
    case disconnected
    case connecting
    case authenticating
    case connected
    case failed(String)
}

@MainActor
final class HAWebSocketClient: ObservableObject, HAClientProtocol {
    /// The app's one connection, which the app hands its views through the
    /// environment.
    static let shared = HAWebSocketClient()

    @Published private(set) var connectionState: HAConnectionState = .disconnected
    @Published private(set) var entities: [HAEntityState] = []
    /// The base URL last used to connect, shared so other views can resolve
    /// HA-hosted image paths without each keeping their own copy.
    @Published private(set) var baseURLString: String = ""
    @Published private(set) var accessToken: String?
    /// HA user id the current access token belongs to, once HA has told us.
    /// Lets the app tell the person holding the phone apart from the rest of
    /// the household.
    @Published private(set) var currentUserId: String?

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    /// Remembered so an unexpected drop can be retried without the caller
    /// having to re-supply credentials.
    private var lastBaseURL: URL?
    private var lastAccessToken: String?
    /// Fallback only — a foreground resume reconnects immediately and bypasses
    /// this entirely. This just covers unexpected mid-session drops: one
    /// second, doubling with each failure in a row up to thirty.
    private static let reconnectDelays: [Duration] = [1, 2, 4, 8, 16, 30].map { .seconds($0) }
    private var failuresInARow = 0

    /// Whether a drop will be retried without anyone stepping in. False after
    /// a manual disconnect or an authentication failure.
    var willRetry: Bool { lastBaseURL != nil && lastAccessToken != nil }

    /// Timing instrumentation for comparing reconnect latency against the
    /// official HA app: logs elapsed time from connect() to each milestone.
    private var connectStartedAt: Date?
    private var hasLoggedFirstEventThisConnection = false

    /// When set, called on `auth_invalid` with the current base URL to swap
    /// the refresh token for a new access token. `rejected` fails the
    /// connection so the UI asks to sign in again; `unreachable` retries.
    var tokenRefresher: ((URL) async -> HAOAuthClient.Refresh)?

    private var nextMessageId = 1
    private var getStatesRequestId: Int?
    private var subscribeEventsRequestId: Int?
    private var currentUserRequestId: Int?
    var browseMediaRequests: [Int: CheckedContinuation<HABrowseMediaResult, Never>] = [:]

    struct PendingSelectSource {
        /// The HA message id for the `select_source` service call.
        let messageId: Int
        /// The source name we're waiting to see in the entity's `source` attribute.
        let expectedSource: String
        /// The entity being changed.
        let entityId: String
        let continuation: CheckedContinuation<SelectSourceResult, Never>
        /// Wall-clock start time for debug timing.
        let startedAt: Date
    }
    var pendingSelectSources: [Int: PendingSelectSource] = [:]
    /// Default probe window: a genuine same-account switch confirms in ~2-3s
    /// in practice, so this doubles that as margin — short enough that a
    /// truly unbound zone (which never confirms at all) is detected quickly
    /// rather than after a long wait. NOT used for confirming a fresh
    /// cross-account handoff — see the `timeout:` param on
    /// `selectSourceConfirmed` and its call site in PlayOnSheet.performSwitch.
    let selectSourceTimeout: Duration = .seconds(5)

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    /// Looks up a live entity by id — the same `entities.first { ... }` scan
    /// every view was repeating individually.
    func entity(_ entityId: String) -> HAEntityState? {
        entities.first { $0.entityId == entityId }
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Shows `DemoMode`'s made-up entities as if connected, without a socket.
    func showDemo(entities: [HAEntityState]) {
        teardownSocket(clearEntities: true)
        baseURLString = "https://demo.invalid/"
        accessToken = "demo"
        self.entities = entities
        connectionState = .connected
    }
    #endif

    func connect(baseURL: URL, accessToken: String) {
        cancelReconnect()
        // Preserve entities across a reconnect (transient drop, foreground
        // resume) so the UI keeps showing last-known state instead of
        // flashing empty while the new connection re-establishes itself.
        teardownSocket(clearEntities: false)
        self.accessToken = accessToken
        self.baseURLString = baseURL.absoluteString
        self.lastBaseURL = baseURL
        self.lastAccessToken = accessToken
        connectionState = .connecting
        connectStartedAt = Date()
        hasLoggedFirstEventThisConnection = false
        Log.homeAssistant.note("connecting to \(baseURL.absoluteString)")

        guard let socketURL = Self.webSocketURL(from: baseURL) else {
            connectionState = .failed("That Home Assistant address isn't a valid URL.")
            return
        }
        let task = URLSession.shared.webSocketTask(with: socketURL)
        webSocketTask = task
        task.resume()

        receiveLoopTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    /// User-initiated disconnect — clears remembered credentials so an
    /// in-flight reconnect attempt won't override it, and clears the entity
    /// cache since this is a deliberate logout/server-change rather than a
    /// transient drop the UI should paper over.
    func disconnect() {
        lastBaseURL = nil
        lastAccessToken = nil
        accessToken = nil
        baseURLString = ""
        currentUserId = nil
        cancelReconnect()
        teardownSocket(clearEntities: true)
        connectionState = .disconnected
    }

    /// Reconnects immediately, bypassing the retry-delay timer entirely —
    /// used when the app returns to the foreground, where waiting on the
    /// fallback timer would make resuming feel sluggish. No-ops if already
    /// connected or a connection attempt is already underway.
    func reconnectAfterForeground() {
        guard let baseURL = lastBaseURL, let accessToken = lastAccessToken else { return }
        switch connectionState {
        case .connected, .connecting, .authenticating:
            Log.homeAssistant.note("reconnectAfterForeground skipped — already \(connectionState)")
            return
        case .disconnected, .failed:
            break
        }
        Log.homeAssistant.note("reconnectAfterForeground — reconnecting immediately")
        cancelReconnect()
        connect(baseURL: baseURL, accessToken: accessToken)
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func teardownSocket(clearEntities: Bool) {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        if clearEntities {
            entities = []
        }
        getStatesRequestId = nil
        subscribeEventsRequestId = nil
        currentUserRequestId = nil
        // Their answers would have come on this socket.
        let browses = browseMediaRequests
        browseMediaRequests = [:]
        for continuation in browses.values {
            continuation.resume(returning: HABrowseMediaResult(
                success: false, result: nil, error: HAResultError(code: nil, message: "Lost the connection to Home Assistant")))
        }
    }

    private static func webSocketURL(from baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = (components.scheme == "http") ? "ws" : "wss"
        components.path = "/api/websocket"
        return components.url
    }

    private func receiveLoop() async {
        guard let task = webSocketTask else { return }
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handleIncoming(text: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleIncoming(text: text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if !Task.isCancelled {
                    connectionState = .failed(error.localizedDescription)
                    scheduleReconnect()
                }
                return
            }
        }
    }

    /// Tries again after a delay using the last-known credentials, as long
    /// as nothing else (a manual disconnect, a fresh connect) has happened
    /// in the meantime. Each failure in a row waits longer.
    private func scheduleReconnect() {
        guard let baseURL = lastBaseURL, let accessToken = lastAccessToken else { return }
        let delay = Self.reconnectDelays[min(failuresInARow, Self.reconnectDelays.count - 1)]
        failuresInARow += 1
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, self.lastBaseURL == baseURL, self.lastAccessToken == accessToken else { return }
            self.connect(baseURL: baseURL, accessToken: accessToken)
        }
    }

    private func handleIncoming(text: String) {
        guard let data = text.data(using: .utf8),
              let envelope = try? decoder.decode(HAEnvelope.self, from: data) else { return }

        switch envelope.type {
        case "auth_required":
            logMilestone("socket connected (auth_required received)")
            sendAuth()
        case "auth_ok":
            logMilestone("auth complete")
            failuresInARow = 0
            connectionState = .connected
            requestStatesAndSubscribe()
        case "auth_invalid":
            if let baseURL = lastBaseURL, let refresher = tokenRefresher {
                let savedBaseURL = baseURL
                teardownSocket(clearEntities: false)
                connectionState = .authenticating
                Task { [weak self] in
                    guard let self else { return }
                    let outcome = await refresher(savedBaseURL)
                    // Signed out, or moved to another server, while refreshing.
                    guard self.lastBaseURL == savedBaseURL else { return }
                    switch outcome {
                    case .refreshed(let newToken):
                        KeychainStore.saveToken(newToken)
                        self.connect(baseURL: savedBaseURL, accessToken: newToken)
                    case .unreachable:
                        // Try again later: the reconnect gets auth_invalid
                        // and comes back here.
                        self.connectionState = .failed("Couldn't reach Home Assistant to renew the sign-in.")
                        self.scheduleReconnect()
                    case .rejected:
                        self.connectionState = .failed("Authentication failed. Please log in again.")
                        self.lastBaseURL = nil
                        self.lastAccessToken = nil
                    }
                }
            } else {
                // Disconnect first: it resets the state to .disconnected,
                // which would hide why.
                disconnect()
                connectionState = .failed("Authentication failed. Check your access token.")
            }
        case "result":
            if envelope.id == getStatesRequestId,
               let states = try? decoder.decode(HAStatesResult.self, from: data),
               states.success, let result = states.result {
                entities = result.sorted { $0.entityId < $1.entityId }
                logMilestone("get_states complete (\(entities.count) entities)")
            } else if envelope.id == currentUserRequestId {
                let user = try? decoder.decode(HACurrentUserResult.self, from: data)
                currentUserId = user?.success == true ? user?.result?.id : nil
            } else if let id = envelope.id, pendingSelectSources[id] != nil {
                // HA acknowledged the service call — now wait for the state_changed event
                // to confirm the source actually switched, unless it already has.
                if let pending = pendingSelectSources[id] {
                    let serviceResult = try? decoder.decode(HAServiceCallResult.self, from: data)
                    if serviceResult?.success == false {
                        pendingSelectSources.removeValue(forKey: id)
                        let elapsed = Date().timeIntervalSince(pending.startedAt)
                        Log.homeAssistant.note("selectSource failed after \(String(format: "%.2f", elapsed))s for \(pending.entityId) → \(pending.expectedSource): \(serviceResult?.error?.message ?? "unknown")")
                        pending.continuation.resume(returning: .error(serviceResult?.error?.message ?? "Service call failed"))
                        return
                    }
                    // On success ack, check if the entity state already reflects the new source
                    // (fast path: state may have updated before the ack arrives).
                    let currentSource = entity(pending.entityId)?.attributeString("source")
                    let normalizedCurrent = currentSource?.normalizedZoneSourceName
                    let normalizedTarget = pending.expectedSource.normalizedZoneSourceName
                    if normalizedCurrent == normalizedTarget {
                        pendingSelectSources.removeValue(forKey: id)
                        let elapsed = Date().timeIntervalSince(pending.startedAt)
                        Log.homeAssistant.note("selectSource confirmed (fast path) in \(String(format: "%.2f", elapsed))s for \(pending.entityId) → \(pending.expectedSource)")
                        pending.continuation.resume(returning: .confirmed)
                    }
                    // Otherwise keep waiting for a state_changed event below.
                }
            } else if let id = envelope.id,
                      let continuation = browseMediaRequests.removeValue(forKey: id) {
                let result = (try? decoder.decode(HABrowseMediaResult.self, from: data))
                    ?? HABrowseMediaResult(success: false, result: nil, error: HAResultError(code: nil, message: "Unable to decode browse result"))
                continuation.resume(returning: result)
            }
        case "event":
            if envelope.id == subscribeEventsRequestId,
               let event = try? decoder.decode(HAStateChangedEvent.self, from: data),
               let newState = event.event.data.newState {
                if !hasLoggedFirstEventThisConnection {
                    hasLoggedFirstEventThisConnection = true
                    logMilestone("first event received")
                }
                if let index = entities.firstIndex(where: { $0.entityId == newState.entityId }) {
                    entities[index] = newState
                } else {
                    entities.append(newState)
                    entities.sort { $0.entityId < $1.entityId }
                }
                // Check if this event satisfies any pending selectSource.
                for (messageId, pending) in pendingSelectSources where pending.entityId == newState.entityId {
                    let newSource = newState.attributeString("source")
                    let normalizedNew = newSource?.normalizedZoneSourceName
                    let normalizedTarget = pending.expectedSource.normalizedZoneSourceName
                    if normalizedNew == normalizedTarget {
                        pendingSelectSources.removeValue(forKey: messageId)
                        let elapsed = Date().timeIntervalSince(pending.startedAt)
                        Log.homeAssistant.note("selectSource confirmed via state_changed in \(String(format: "%.2f", elapsed))s for \(pending.entityId) → \(pending.expectedSource)")
                        pending.continuation.resume(returning: .confirmed)
                    }
                }
            }
        default:
            break
        }
    }

    private func sendAuth() {
        connectionState = .authenticating
        guard let accessToken else { return }
        send(HAAuthMessage(accessToken: accessToken))
    }

    private func requestStatesAndSubscribe() {
        let statesId = nextId()
        getStatesRequestId = statesId
        send(HAGetStatesMessage(id: statesId))

        let subscribeId = nextId()
        subscribeEventsRequestId = subscribeId
        send(HASubscribeEventsMessage(id: subscribeId))

        let currentUserId = nextId()
        currentUserRequestId = currentUserId
        send(HACurrentUserMessage(id: currentUserId))
    }

    // MARK: Plumbing for the extension files
    //
    // Not private only because the service, select-source and speaker-claim
    // extensions live in their own files. Nothing outside this client calls
    // them.

    func nextId() -> Int {
        defer { nextMessageId += 1 }
        return nextMessageId
    }

    /// Logs elapsed time since `connect()` was called, for comparing
    /// reconnect latency against the official HA app.
    func logMilestone(_ name: String) {
        guard let connectStartedAt else { return }
        let elapsed = Date().timeIntervalSince(connectStartedAt)
        Log.homeAssistant.note("[\(String(format: "%.2f", elapsed))s] \(name)")
    }

    func send<T: Encodable>(_ message: T) {
        guard let task = webSocketTask,
              let data = try? encoder.encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { error in
            if let error {
                Log.homeAssistant.note("send failed — \(error.localizedDescription)")
            }
        }
    }
}

import Foundation
import Combine

struct AssistantMessage: Identifiable, Equatable {
    let id: String
    let isUser: Bool
    var text: String
}

/// Text-only transcript: tool calls/results and hidden reasoning are never rendered.
struct AssistantTranscript {
    var messages: [AssistantMessage] = []
    private var sequences: [String: Int] = [:]
    private(set) var finishedRuns: Set<String> = []

    mutating func replaceHistory(_ payload: [String: Any]) {
        messages = (payload["messages"] as? [[String: Any]] ?? []).enumerated().compactMap { index, message in
            guard let role = message["role"] as? String, role == "user" || role == "assistant" else { return nil }
            let text = Self.text(message)
            guard !text.isEmpty else { return nil }
            return AssistantMessage(id: "history:\(index)", isUser: role == "user", text: text)
        }
        sequences.removeAll()
        finishedRuns.removeAll()
    }

    /// Returns false for a duplicate or malformed event.
    @discardableResult
    mutating func apply(_ event: [String: Any]) -> Bool {
        guard let runID = event["runId"] as? String, let state = event["state"] as? String,
              ["delta", "final", "aborted", "error"].contains(state) else { return false }
        if let sequence = event["seq"] as? Int {
            if let last = sequences[runID], sequence <= last { return false }
            sequences[runID] = sequence
        }
        if state != "delta" { finishedRuns.insert(runID) }
        let id = "assistant:\(runID)"
        let index = messages.firstIndex { $0.id == id }
        let snapshot = (event["message"] as? [String: Any]).map(Self.text) ?? ""
        let delta = event["deltaText"] as? String
        let text: String
        if state == "delta", let delta {
            if event["replace"] as? Bool == true { text = delta }
            else { text = (index.map { messages[$0].text } ?? "") + delta }
        } else if !snapshot.isEmpty { text = snapshot }
        else { text = index.map { messages[$0].text } ?? "" }
        if let index { messages[index].text = text }
        else if !text.isEmpty { messages.append(AssistantMessage(id: id, isUser: false, text: text)) }
        return true
    }

    static func text(_ message: [String: Any]) -> String {
        if let text = message["content"] as? String { return text }
        return (message["content"] as? [[String: Any]] ?? []).compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
    }
}

@MainActor
final class AssistantChatModel: ObservableObject {
    enum State: Equatable {
        case needsPairing, connecting, waitingForApproval, connected, disconnected
    }

    @Published private(set) var state: State = .needsPairing
    @Published private(set) var transcript = AssistantTranscript()
    @Published private(set) var errorMessage: String?
    @Published private(set) var gatewayHost: String?
    @Published private(set) var deviceID: String?
    @Published private(set) var activeRunID: String?
    @Published private(set) var isLoadingHistory = false
    private let store: any OpenClawCredentialStoring
    private let gateway: OpenClawGatewayClient
    private var configuration: AssistantConfiguration?
    private var setup: OpenClawSetupCode?
    private var connectionTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var generation = UUID()
    private var bufferedEvents: [[String: Any]] = []
    private var demo = false

    init(store: (any OpenClawCredentialStoring)? = nil, gateway: OpenClawGatewayClient? = nil) {
        self.store = store ?? OpenClawCredentialStore()
        self.gateway = gateway ?? OpenClawGatewayClient()
        self.gateway.onChat = { [weak self] event in self?.receive(event) }
    }

    func activate(configuration: AssistantConfiguration, demo: Bool = false) {
        if self.configuration != configuration || self.demo != demo {
            pause()
            transcript = AssistantTranscript()
            self.configuration = configuration
            self.demo = demo
        }
        if demo {
            state = .connected
            if transcript.messages.isEmpty {
                transcript.messages = [
                    AssistantMessage(id: "demo:user", isUser: true, text: "What's the temperature downstairs?"),
                    AssistantMessage(id: "demo:assistant", isUser: false, text: "It's 71°F downstairs.")
                ]
            }
            return
        }
        guard connectionTask == nil else { return }
        let id = generation
        connectionTask = Task { [weak self] in
            await self?.connectionLoop(configuration, generation: id)
        }
    }

    /// Called for backgrounding, leaving the tab, removing config or signing out.
    func pause() {
        generation = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        sendTask?.cancel()
        sendTask = nil
        gateway.disconnect()
        isLoadingHistory = false
        bufferedEvents = []
        if activeRunID != nil {
            errorMessage = "The connection was interrupted. Check the conversation before sending the command again."
        }
        activeRunID = nil
        if state != .needsPairing { state = .disconnected }
    }

    func pair(_ code: String) throws {
        let setup = try OpenClawSetupCode.parse(code)
        pause()
        self.setup = setup
        transcript = AssistantTranscript()
        errorMessage = nil
        guard let configuration else { return }
        activate(configuration: configuration)
    }

    func forget() {
        pause()
        do {
            try store.forget()
            setup = nil
            gatewayHost = nil
            deviceID = nil
            transcript = AssistantTranscript()
            errorMessage = nil
            state = .needsPairing
        } catch { errorMessage = OpenClawError.keychain.localizedDescription }
    }

    func reconnect() {
        guard let configuration else { return }
        pause()
        activate(configuration: configuration, demo: demo)
    }

    func send(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state == .connected, !isLoadingHistory, activeRunID == nil,
              !text.isEmpty, text.count <= 16_000, let configuration else { return }
        errorMessage = nil
        let runID = UUID().uuidString
        transcript.messages.append(AssistantMessage(id: "user:\(runID)", isUser: true, text: text))
        if demo {
            transcript.messages.append(AssistantMessage(id: "assistant:\(runID)", isUser: false, text: "This is a demo conversation. No command was sent."))
            return
        }
        activeRunID = runID
        let id = generation
        sendTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await gateway.send(text, idempotencyKey: runID, configuration: configuration)
                guard generation == id, !Task.isCancelled else { return }
                if activeRunID == runID, let actualRun = result["runId"] as? String {
                    activeRunID = transcript.finishedRuns.contains(actualRun) ? nil : actualRun
                }
            } catch {
                guard generation == id, !Task.isCancelled else { return }
                activeRunID = nil
                errorMessage = "Couldn't confirm whether the command was accepted. Reconnect and check the conversation before resending."
            }
        }
    }

    func stop() async {
        guard let activeRunID, let configuration else { return }
        let id = generation
        do {
            try await gateway.abort(runID: activeRunID, configuration: configuration)
            guard generation == id else { return }
            if self.activeRunID == activeRunID { self.activeRunID = nil }
        } catch {
            guard generation == id else { return }
            errorMessage = "Couldn't confirm cancellation. The command may still be running."
        }
    }

    private func connectionLoop(_ configuration: AssistantConfiguration, generation id: UUID) async {
        defer { if generation == id { connectionTask = nil } }
        var attempts = 0
        while !Task.isCancelled, generation == id {
            do {
                let credential = setup == nil ? try store.credential() : nil
                guard setup != nil || credential != nil else {
                    state = .needsPairing
                    return
                }
                let identity = try store.identity()
                deviceID = identity.deviceID
                if let setup {
                    guard setup.expiresAt.map({ $0 > Date() }) ?? true else { throw OpenClawError.expiredSetupCode }
                    gatewayHost = setup.url.host
                    state = .connecting
                    let hello = try await gateway.connect(url: setup.url, identity: identity, token: setup.bootstrapToken, bootstrap: true)
                    guard generation == id, !Task.isCancelled else { return }
                    let paired = try OpenClawCredential.from(hello: hello, url: setup.url, bootstrap: true)
                    try store.save(paired)
                    self.setup = nil
                    gateway.disconnect()
                    continue
                }
                guard let credential, let url = URL(string: credential.gatewayURL) else { throw OpenClawError.invalidResponse }
                gatewayHost = url.host
                state = .connecting
                let hello = try await gateway.connect(url: url, identity: identity, token: credential.token, bootstrap: false)
                guard generation == id, !Task.isCancelled else { return }
                if let auth = hello["auth"] as? [String: Any], auth["deviceToken"] != nil {
                    try store.save(OpenClawCredential.from(hello: hello, url: url, bootstrap: false))
                }
                state = .connected
                attempts = 0
                isLoadingHistory = true
                bufferedEvents = []
                let history = try await gateway.history(configuration: configuration)
                guard generation == id, !Task.isCancelled else { return }
                transcript.replaceHistory(history)
                isLoadingHistory = false
                let events = bufferedEvents
                bufferedEvents = []
                for event in events { receive(event) }
                try await gateway.waitForDisconnect()
            } catch {
                guard generation == id, !Task.isCancelled else { return }
                gateway.disconnect()
                isLoadingHistory = false
                bufferedEvents = []
                if activeRunID != nil {
                    errorMessage = "The connection was interrupted. Check the conversation before sending the command again."
                    activeRunID = nil
                }
                let failure = error as? OpenClawError
                if failure?.isPendingApproval == true, setup != nil {
                    state = .waitingForApproval
                } else if failure?.requiresPairing == true || failure == .expiredSetupCode || failure == .unsafeCredential || failure == .unsupportedGateway || failure == .keychain {
                    self.setup = nil
                    state = .needsPairing
                    errorMessage = failure?.localizedDescription
                    return
                } else {
                    state = .disconnected
                    errorMessage = failure?.localizedDescription ?? "Couldn't connect to the gateway. Check its address and certificate."
                }
                attempts += 1
                let delay = state == .waitingForApproval ? 3.0 : min(30.0, pow(2, Double(min(attempts, 5))))
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func receive(_ event: [String: Any]) {
        guard let configuration, event["sessionKey"] as? String == configuration.sessionKey,
              (event["agentId"] as? String).map({ $0 == configuration.agent }) ?? true else { return }
        if isLoadingHistory {
            // A bounded queue while the initial history RPC is in flight.
            if bufferedEvents.count < 1000 { bufferedEvents.append(event) }
            return
        }
        guard transcript.apply(event) else { return }
        let runID = event["runId"] as? String
        switch event["state"] as? String {
        case "delta":
            if activeRunID == nil { activeRunID = runID }
        case "final", "aborted", "error":
            if activeRunID == runID { activeRunID = nil }
            if event["state"] as? String == "error" { errorMessage = "The assistant couldn't finish that request. Check the conversation before trying again." }
        default: break
        }
    }
}

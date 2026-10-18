import Foundation

@MainActor
protocol OpenClawSocket: AnyObject {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

@MainActor
private final class URLSessionOpenClawSocket: OpenClawSocket {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 2 * 1024 * 1024
        task.resume()
    }

    func send(_ data: Data) async throws {
        guard let text = String(data: data, encoding: .utf8) else { throw OpenClawError.invalidResponse }
        try await task.send(.string(text))
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: throw OpenClawError.invalidResponse
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

/// One socket, a signed challenge, bounded RPCs and an event stream. Never logs frames.
@MainActor
final class OpenClawGatewayClient {
    typealias Object = [String: Any]
    typealias SocketFactory = (URL) -> any OpenClawSocket
    var onChat: ((Object) -> Void)?
    private let makeSocket: SocketFactory
    private let requestTimeout: TimeInterval
    private var socket: (any OpenClawSocket)?
    private var receiver: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var generation = UUID()
    private var connected = false
    private var lastReceived = Date()
    private var challenge: CheckedContinuation<Object, Error>?
    private var disconnected: CheckedContinuation<Void, Error>?
    private var pending: [String: PendingRequest] = [:]

    private struct PendingRequest {
        let continuation: CheckedContinuation<Object, Error>
        let deadline: Task<Void, Never>
    }

    init(requestTimeout: TimeInterval = 30, makeSocket: SocketFactory? = nil) {
        self.requestTimeout = requestTimeout
        self.makeSocket = makeSocket ?? { URLSessionOpenClawSocket(url: $0) }
    }

    func connect(url: URL, identity: OpenClawIdentity, token: String, bootstrap: Bool) async throws -> Object {
        disconnect()
        _ = try OpenClawSetupCode.validatedURL(url.absoluteString)
        let id = generation
        let socket = makeSocket(url)
        self.socket = socket
        lastReceived = Date()
        let challengeDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.generation == id else { return }
            self.fail(OpenClawError.timeout)
        }
        defer { challengeDeadline.cancel() }
        do {
            let challenge = try await withCheckedThrowingContinuation { continuation in
                self.challenge = continuation
                receiver = Task { [weak self] in
                    do {
                        while !Task.isCancelled {
                            let data = try await socket.receive()
                            guard let self, self.generation == id else { return }
                            try self.receive(data)
                        }
                    } catch {
                        guard let self, self.generation == id else { return }
                        self.fail(error is OpenClawError ? error : OpenClawError.disconnected)
                    }
                }
            }
            try Task.checkCancellation()
            guard generation == id, let nonce = challenge["nonce"] as? String, !nonce.isEmpty,
                  let timestamp = challenge["ts"] as? NSNumber else { throw OpenClawError.invalidResponse }
            let role = bootstrap ? "node" : "operator"
            let scopes = bootstrap ? [] : OpenClawCredential.connectionScopes
            let hello = try await request("connect", params: [
                "minProtocol": 4, "maxProtocol": 4,
                "client": ["id": "openclaw-ios", "displayName": "Hassonic", "version": "1.0",
                           "platform": "ios", "deviceFamily": "ios", "mode": bootstrap ? "node" : "ui"],
                "role": role, "scopes": scopes,
                "caps": bootstrap ? [] : ["chat-only-assistant-text"],
                "commands": [], "permissions": [:] as Object,
                "auth": [bootstrap ? "bootstrapToken" : "token": token],
                "device": try identity.signedDevice(role: role, scopes: scopes, token: token, nonce: nonce, signedAt: timestamp.int64Value)
            ])
            try Task.checkCancellation()
            guard generation == id, hello["type"] as? String == "hello-ok", hello["protocol"] as? Int == 4 else {
                throw OpenClawError.unsupportedGateway
            }
            connected = true
            let policy = hello["policy"] as? Object
            let tick = max(1, (policy?["tickIntervalMs"] as? Double ?? 30_000) / 1000)
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(tick))
                    guard !Task.isCancelled, let self, self.generation == id else { return }
                    if Date().timeIntervalSince(self.lastReceived) > tick * 2 + 5 {
                        self.fail(OpenClawError.timeout)
                        return
                    }
                }
            }
            return hello
        } catch {
            if generation == id { fail(error) }
            throw error
        }
    }

    func waitForDisconnect() async throws {
        guard connected else { throw OpenClawError.disconnected }
        try await withCheckedThrowingContinuation { disconnected = $0 }
    }

    func history(configuration: AssistantConfiguration) async throws -> Object {
        try await request("chat.history", params: Self.chatParams(configuration, extra: ["limit": 100]))
    }

    func send(_ text: String, idempotencyKey: String, configuration: AssistantConfiguration) async throws -> Object {
        try await request("chat.send", params: Self.chatParams(configuration, extra: ["message": text, "idempotencyKey": idempotencyKey]))
    }

    func abort(runID: String, configuration: AssistantConfiguration) async throws {
        _ = try await request("chat.abort", params: Self.chatParams(configuration, extra: ["runId": runID]))
    }

    static func chatParams(_ configuration: AssistantConfiguration, extra: Object = [:]) -> Object {
        var params = extra
        // These cannot be overridden by a composer, event or caller-provided extras.
        params["sessionKey"] = configuration.sessionKey
        params["agentId"] = AssistantConfiguration.agentID
        return params
    }

    func disconnect() {
        fail(OpenClawError.disconnected)
    }

    private func request(_ method: String, params: Object) async throws -> Object {
        guard let socket else { throw OpenClawError.disconnected }
        try Task.checkCancellation()
        let id = UUID().uuidString
        let connectionID = generation
        let data = try JSONSerialization.data(withJSONObject: ["type": "req", "id": id, "method": method, "params": params])
        return try await withCheckedThrowingContinuation { continuation in
            let deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.requestTimeout ?? 30))
                guard !Task.isCancelled, let self, self.generation == connectionID else { return }
                self.finish(id, result: .failure(OpenClawError.timeout))
            }
            pending[id] = PendingRequest(continuation: continuation, deadline: deadline)
            Task { [weak self] in
                do { try await socket.send(data) }
                catch {
                    guard let self, self.generation == connectionID else { return }
                    self.fail(OpenClawError.disconnected)
                }
            }
        }
    }

    private func receive(_ data: Data) throws {
        guard data.count <= 2 * 1024 * 1024,
              let frame = try JSONSerialization.jsonObject(with: data) as? Object else { throw OpenClawError.invalidResponse }
        lastReceived = Date()
        switch frame["type"] as? String {
        case "event":
            let payload = frame["payload"] as? Object ?? [:]
            if frame["event"] as? String == "connect.challenge", let waiter = challenge {
                challenge = nil
                waiter.resume(returning: payload)
            } else if frame["event"] as? String == "chat", connected {
                onChat?(payload)
            }
        case "res":
            guard let id = frame["id"] as? String else { throw OpenClawError.invalidResponse }
            if frame["ok"] as? Bool == true {
                finish(id, result: .success(frame["payload"] as? Object ?? [:]))
            } else {
                let error = frame["error"] as? Object ?? [:]
                let details = error["details"] as? Object
                // Do not display the gateway's arbitrary error text: it may contain credentials or transcript text.
                let rawCode = error["code"] as? String ?? "UNKNOWN"
                let code = rawCode.range(of: #"^[A-Z0-9_]{1,64}$"#, options: .regularExpression) != nil ? rawCode : "UNKNOWN"
                let failure: OpenClawError = code == "INVALID_REQUEST" && error["message"] as? String == "Unknown agent id \"hassonic\""
                    ? .agentUnavailable : .rpc(code: code, detail: details?["code"] as? String)
                finish(id, result: .failure(failure))
            }
        default: break
        }
    }

    private func finish(_ id: String, result: Result<Object, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.deadline.cancel()
        request.continuation.resume(with: result)
    }

    private func fail(_ error: Error) {
        generation = UUID()
        connected = false
        receiver?.cancel()
        receiver = nil
        watchdog?.cancel()
        watchdog = nil
        socket?.close()
        socket = nil
        challenge?.resume(throwing: error)
        challenge = nil
        disconnected?.resume(throwing: error)
        disconnected = nil
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.deadline.cancel()
            request.continuation.resume(throwing: error)
        }
    }
}

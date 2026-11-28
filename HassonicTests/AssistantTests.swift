import CryptoKit
import XCTest
@testable import Hassonic

final class AssistantConfigurationTests: XCTestCase {
    private let minimal = """
    version: 1
    pages:
      - id: home
        title: Home
        system_icon: house
        sections: []
    """

    func testOptionalAssistantAlwaysUsesHassonicWithConfigurableSession() throws {
        XCTAssertNil(try AppConfigurationParser.parse(minimal).assistant)
        let config = try AppConfigurationParser.parse(minimal + "\nassistant: {}\n")
        XCTAssertEqual(config.assistant, AssistantConfiguration())
        XCTAssertEqual(config.assistant?.sessionKey, "agent:hassonic:main")
        for legacyAgent in ["family", "main", "helper", "hassonic"] {
            let other = try AppConfigurationParser.parse(minimal + "\nassistant:\n  agent: \(legacyAgent)\n  session: phone\n")
            XCTAssertEqual(other.assistant?.agent, "hassonic")
            XCTAssertEqual(other.assistant?.sessionKey, "agent:hassonic:phone")
        }
    }

    func testInvalidSessionAndReservedPageAreRejected() {
        for block in ["session: ''", "session: Main", "session: 'other:session'", "title: ''"] {
            XCTAssertThrowsError(try AppConfigurationParser.parse(minimal + "\nassistant:\n  " + block + "\n"))
        }
        XCTAssertThrowsError(try AppConfigurationParser.parse(minimal.replacingOccurrences(of: "id: home", with: "id: assistant") + "\nassistant:\n  agent: family\n"))
    }
}

final class OpenClawIdentityTests: XCTestCase {
    private func code(_ values: [String: Any]) throws -> String {
        try JSONSerialization.data(withJSONObject: values).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func testSetupCodeAcceptsLimitedBootstrapPayloadAndPairURL() throws {
        let raw = try code(["url": "wss://gateway.example", "bootstrapToken": "short-lived", "expiresAtMs": 20_000])
        let parsed = try OpenClawSetupCode.parse("  oc-pair://\(raw)\n", now: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(parsed.url.host, "gateway.example")
        XCTAssertEqual(parsed.bootstrapToken, "short-lived")
    }

    func testRejectsExpiredMalformedSharedAndInsecureCodes() throws {
        for values: [String: Any] in [
            ["url": "ws://gateway.example", "bootstrapToken": "x"],
            ["url": "https://gateway.example", "bootstrapToken": "x"],
            ["url": "wss://user:password@gateway.example", "bootstrapToken": "x"],
            ["url": "wss://gateway.example?token=secret", "bootstrapToken": "x"],
            ["url": "wss://gateway.example", "token": "shared"],
            ["url": "wss://gateway.example", "bootstrapToken": "x", "expiresAtMs": 1],
            ["url": "wss://gateway.example", "bootstrapToken": "x", "expiresAtMs": true]
        ] { XCTAssertThrowsError(try OpenClawSetupCode.parse(code(values))) }
        XCTAssertThrowsError(try OpenClawSetupCode.parse("garbage!"))
    }

    func testSignatureMatchesOpenClawCompatibilityPayloadAndVerifies() throws {
        // Field-order fixture from OpenClaw DeviceAuthPayload.swift's v2 compatibility contract.
        XCTAssertEqual(OpenClawIdentity.signaturePayload(deviceID: "device", role: "operator", scopes: ["operator.read", "operator.write"], token: "token", nonce: "nonce", signedAt: 123),
                       "v2|device|openclaw-ios|ui|operator|operator.read,operator.write|123|token|nonce")
        let identity = try OpenClawIdentity(rawRepresentation: Data(repeating: 7, count: 32))
        let device = try identity.signedDevice(role: "operator", scopes: [], token: "x", nonce: "n", signedAt: 1)
        let signature = try XCTUnwrap(device["signature"] as? String)
        let base64 = signature.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let data = try XCTUnwrap(Data(base64Encoded: base64 + "=="))
        let payload = OpenClawIdentity.signaturePayload(deviceID: identity.deviceID, role: "operator", scopes: [], token: "x", nonce: "n", signedAt: 1)
        XCTAssertTrue(identity.privateKey.publicKey.isValidSignature(data, for: Data(payload.utf8)))
        XCTAssertEqual(identity.deviceID.count, 64)
    }

    func testBootstrapKeepsOnlyOperatorTokenAndRejectsAdmin() throws {
        let node: [String: Any] = ["role": "node", "deviceToken": "node-secret", "scopes": []]
        let op: [String: Any] = ["role": "operator", "deviceToken": "operator-secret", "scopes": OpenClawCredential.chatScopes]
        let hello: [String: Any] = ["auth": node.merging(["deviceTokens": [op]]) { _, new in new }]
        let url = try XCTUnwrap(URL(string: "wss://gateway.example"))
        let credential = try OpenClawCredential.from(hello: hello, url: url, bootstrap: true)
        XCTAssertEqual(credential.token, "operator-secret")
        XCTAssertThrowsError(try OpenClawCredential(gatewayURL: url.absoluteString, token: "admin", scopes: ["operator.admin"]).validated())
        XCTAssertThrowsError(try OpenClawCredential(gatewayURL: url.absoluteString, token: "x", scopes: OpenClawCredential.chatScopes + ["operator.pairing"]).validated())
    }
}

final class AssistantTranscriptTests: XCTestCase {
    func testDeltaAppendReplaceFinalAndSequenceDeduplication() {
        var transcript = AssistantTranscript()
        func event(_ seq: Int, _ state: String, _ extras: [String: Any]) -> [String: Any] {
            ["runId": "r", "seq": seq, "state": state].merging(extras) { _, new in new }
        }
        transcript.apply(event(1, "delta", ["deltaText": "Hello"]))
        transcript.apply(event(1, "delta", ["deltaText": " duplicate"]))
        transcript.apply(event(2, "delta", ["deltaText": " world"]))
        XCTAssertEqual(transcript.messages.first?.text, "Hello world")
        transcript.apply(event(3, "delta", ["deltaText": "Replacement", "replace": true]))
        transcript.apply(event(4, "final", ["message": ["content": [["type": "text", "text": "Complete"]]]]))
        XCTAssertEqual(transcript.messages.count, 1)
        XCTAssertEqual(transcript.messages.first?.text, "Complete")
        XCTAssertTrue(transcript.finishedRuns.contains("r"))
    }

    func testHistoryDoesNotRenderToolsOrReasoning() {
        var transcript = AssistantTranscript()
        transcript.replaceHistory(["messages": [
            ["role": "user", "content": "Hi"],
            ["role": "toolResult", "content": "private tool output"],
            ["role": "assistant", "content": [["type": "thinking", "thinking": "private reasoning"], ["type": "text", "text": "Hello"]]]
        ]])
        XCTAssertEqual(transcript.messages.map(\.text), ["Hi", "Hello"])
    }
}

@MainActor
final class AssistantRoutingTests: XCTestCase {
    func testAssistantLinkOpensSheetOnCurrentPageAndRemovalDismissesIt() throws {
        let router = AppRouter()
        let url = try XCTUnwrap(URL(string: "hassonic://assistant"))
        router.handle(url: url)
        XCTAssertEqual(router.selectedTab, .connection)
        router.setAssistantEnabled(true)
        router.handle(url: url)
        XCTAssertEqual(router.presentedSheet, .assistant)
        XCTAssertEqual(router.selectedTab, .connection)
        router.setAssistantEnabled(false)
        XCTAssertNil(router.presentedSheet)
    }

    func testAllChatRPCsPinHassonicEvenWhenExtrasTryToOverrideIt() {
        let config = AssistantConfiguration(session: "phone")
        let params = OpenClawGatewayClient.chatParams(config, extra: ["agentId": "evil", "sessionKey": "agent:main:main"])
        XCTAssertEqual(params["agentId"] as? String, "hassonic")
        XCTAssertEqual(params["sessionKey"] as? String, "agent:hassonic:phone")
    }

    func testNotificationURLAcceptsOnlyAppLinks() {
        XCTAssertEqual(NotificationLink.url(from: ["url": "hassonic://assistant"])?.host, "assistant")
        for info: [AnyHashable: Any] in [[:], ["url": 42], ["url": "https://example.com"], ["url": "hassonic://user:secret@assistant"]] {
            XCTAssertNil(NotificationLink.url(from: info))
        }
    }
}

@MainActor
final class FakeOpenClawSocket: OpenClawSocket {
    var sent: [[String: Any]] = []
    var onSend: (([String: Any]) -> Void)?
    var closed = false
    private var queue: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?

    init() { emit(["type": "event", "event": "connect.challenge", "payload": ["nonce": "fixture", "ts": 123]]) }

    func emit(_ frame: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: frame)
        if let waiter { self.waiter = nil; waiter.resume(returning: data) }
        else { queue.append(data) }
    }

    func send(_ data: Data) async throws {
        let frame = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        sent.append(frame)
        onSend?(frame)
    }

    func receive() async throws -> Data {
        if closed { throw OpenClawError.disconnected }
        if !queue.isEmpty { return queue.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func close() {
        closed = true
        waiter?.resume(throwing: OpenClawError.disconnected)
        waiter = nil
    }

    func reply(_ request: [String: Any], payload: [String: Any] = [:]) {
        emit(["type": "res", "id": request["id"]!, "ok": true, "payload": payload])
    }

    func respondToChat() {
        onSend = { [weak self] frame in
            guard let self else { return }
            if frame["method"] as? String == "connect" {
                reply(frame, payload: ["type": "hello-ok", "protocol": 4,
                    "auth": ["role": "operator", "deviceToken": "test-token", "scopes": OpenClawCredential.chatScopes],
                    "policy": ["tickIntervalMs": 30_000]])
            } else { reply(frame, payload: ["messages": []]) }
        }
    }
}

@MainActor
final class OpenClawGatewayTests: XCTestCase {
    func testSignedHandshakeAndHistoryRouting() async throws {
        let socket = FakeOpenClawSocket()
        socket.respondToChat()
        let client = OpenClawGatewayClient(makeSocket: { _ in socket })
        defer { client.disconnect() }
        _ = try await client.connect(url: URL(string: "wss://gateway.example")!, identity: OpenClawIdentity(), token: "test-token", bootstrap: false)
        _ = try await client.history(configuration: AssistantConfiguration())
        let connect = socket.sent[0]["params"] as! [String: Any]
        XCTAssertEqual(connect["role"] as? String, "operator")
        XCTAssertEqual(connect["scopes"] as? [String], OpenClawCredential.connectionScopes)
        XCTAssertTrue((connect["scopes"] as? [String])?.contains("operator.approvals") == true,
                      "The admitted run needs approvals scope to request and wait for plugin approvals.")
        XCTAssertFalse((connect["scopes"] as? [String])?.contains("operator.admin") == true)
        XCTAssertFalse((connect["scopes"] as? [String])?.contains("operator.pairing") == true)
        XCTAssertNotNil((connect["device"] as? [String: Any])?["signature"])
        let history = socket.sent[1]["params"] as! [String: Any]
        XCTAssertEqual(history["sessionKey"] as? String, "agent:hassonic:main")
        _ = try await client.send("hello", idempotencyKey: "test-run", configuration: AssistantConfiguration())
        try await client.abort(runID: "test-run", configuration: AssistantConfiguration())
        for request in socket.sent.dropFirst() {
            let params = request["params"] as! [String: Any]
            XCTAssertEqual(params["agentId"] as? String, "hassonic")
            XCTAssertEqual(params["sessionKey"] as? String, "agent:hassonic:main")
        }
    }

    func testTimeoutAndDisconnectSettleOutstandingRequests() async throws {
        let socket = FakeOpenClawSocket()
        socket.respondToChat()
        let client = OpenClawGatewayClient(requestTimeout: 0.02, makeSocket: { _ in socket })
        _ = try await client.connect(url: URL(string: "wss://gateway.example")!, identity: OpenClawIdentity(), token: "test-token", bootstrap: false)
        socket.onSend = nil
        do {
            _ = try await client.history(configuration: AssistantConfiguration())
            XCTFail("The RPC should time out")
        } catch { XCTAssertEqual(error as? OpenClawError, .timeout) }
        let request = Task { try await client.history(configuration: AssistantConfiguration()) }
        await Task.yield()
        client.disconnect()
        do { _ = try await request.value; XCTFail("Disconnect should fail outstanding work") }
        catch { XCTAssertEqual(error as? OpenClawError, .disconnected) }
        XCTAssertTrue(socket.closed)
    }

    func testBootstrapRequestsNoNodeCapabilitiesOrOperatorScopes() async throws {
        let socket = FakeOpenClawSocket()
        socket.respondToChat()
        let client = OpenClawGatewayClient(makeSocket: { _ in socket })
        defer { client.disconnect() }
        _ = try await client.connect(url: URL(string: "wss://gateway.example")!, identity: OpenClawIdentity(), token: "bootstrap", bootstrap: true)
        let params = socket.sent[0]["params"] as! [String: Any]
        XCTAssertEqual(params["role"] as? String, "node")
        XCTAssertEqual(params["scopes"] as? [String], [])
        XCTAssertEqual(params["commands"] as? [String], [])
        XCTAssertEqual((params["auth"] as? [String: String])?["bootstrapToken"], "bootstrap")
    }
}

@MainActor
final class FakeOpenClawStore: OpenClawCredentialStoring {
    var reads = 0
    private let storedIdentity = try! OpenClawIdentity()
    var saved: OpenClawCredential? = OpenClawCredential(gatewayURL: "wss://gateway.example", token: "test-token", scopes: OpenClawCredential.chatScopes)
    func identity() throws -> OpenClawIdentity { reads += 1; return storedIdentity }
    func credential() throws -> OpenClawCredential? { reads += 1; return saved }
    func save(_ credential: OpenClawCredential) throws { saved = credential }
    func forget() throws { saved = nil }
}

@MainActor
final class AssistantLifecycleTests: XCTestCase {
    func testEventsFromOtherAgentsAreIgnored() async throws {
        let socket = FakeOpenClawSocket()
        socket.respondToChat()
        let model = AssistantChatModel(store: FakeOpenClawStore(), gateway: OpenClawGatewayClient(makeSocket: { _ in socket }))
        defer { model.pause() }
        model.activate(configuration: AssistantConfiguration())
        for _ in 0..<200 where model.state != .connected { await Task.yield() }
        XCTAssertEqual(model.state, .connected)
        XCTAssertFalse(socket.sent.contains { $0["method"] as? String == "chat.history" })
        model.send("Test directive")
        let runID = try XCTUnwrap(model.directive?.runID)
        for (run, session, agent, text) in [
            (runID, "agent:family:main", "family", "Wrong session"),
            (runID, "agent:hassonic:main", "family", "Wrong agent"),
            ("someone-else", "agent:hassonic:main", "hassonic", "Other device"),
            (runID, "agent:hassonic:main", "hassonic", "Allowed")
        ] {
            socket.emit(["type": "event", "event": "chat", "payload": [
                "runId": run, "sessionKey": session, "agentId": agent, "seq": 1,
                "state": "final", "message": ["content": text]
            ]])
        }
        for _ in 0..<200 where model.directive?.status == .running { await Task.yield() }
        XCTAssertEqual(model.directive?.response, "Allowed")
        XCTAssertEqual(model.directive?.status, .completed)
    }

    func testConstructionAndDemoDoNotReadKeychainOrConnect() {
        let store = FakeOpenClawStore()
        var connections = 0
        let gateway = OpenClawGatewayClient(makeSocket: { _ in connections += 1; return FakeOpenClawSocket() })
        let model = AssistantChatModel(store: store, gateway: gateway)
        XCTAssertEqual(store.reads, 0)
        model.activate(configuration: AssistantConfiguration(), demo: true)
        XCTAssertEqual(store.reads, 0)
        XCTAssertEqual(connections, 0)
        XCTAssertTrue(model.transcript.messages.isEmpty)
        XCTAssertNil(model.directive)
        model.send("Preview directive")
        XCTAssertEqual(model.directive?.status, .completed)
        model.pause()
    }

    func testPauseClosesSocketAndDoesNotReconnectOrResend() async throws {
        let store = FakeOpenClawStore()
        let socket = FakeOpenClawSocket()
        socket.respondToChat()
        var connections = 0
        let gateway = OpenClawGatewayClient(makeSocket: { _ in connections += 1; return socket })
        let model = AssistantChatModel(store: store, gateway: gateway)
        model.activate(configuration: AssistantConfiguration())
        for _ in 0..<200 where model.state != .connected { await Task.yield() }
        XCTAssertEqual(model.state, .connected)
        model.pause()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(socket.closed)
        XCTAssertEqual(connections, 1)
        XCTAssertFalse(socket.sent.contains { $0["method"] as? String == "chat.send" })
    }
}

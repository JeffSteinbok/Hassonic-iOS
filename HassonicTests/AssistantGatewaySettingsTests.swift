import XCTest
@testable import Hassonic

final class OpenClawGatewayAddressTests: XCTestCase {
    func testAcceptsHostnameHTTPSAndWSSWithPortAndPath() throws {
        for (input, expected) in [
            ("  new-host.example  ", "wss://new-host.example"),
            ("https://new-host.example:443/gateway", "wss://new-host.example:443/gateway"),
            ("wss://new-host.example:18789", "wss://new-host.example:18789"),
            ("new-host.example/assistant", "wss://new-host.example/assistant")
        ] {
            XCTAssertEqual(try OpenClawSetupCode.gatewayAddress(input).absoluteString, expected)
        }
    }

    func testRejectsInsecureMalformedAndCredentialBearingAddresses() {
        for input in ["", "   ", "http://host.example", "ws://host.example", "ftp://host.example",
                      "wss://", "new host.example", "wss://user:secret@host.example",
                      "https://host.example?token=secret", "host.example#secret",
                      "wss://host.example:0", "wss://host.example:65536"] {
            XCTAssertThrowsError(try OpenClawSetupCode.gatewayAddress(input), input)
        }
    }
}

@MainActor
final class AssistantGatewaySettingsTests: XCTestCase {
    func testSettingsLoadsSavedAddressWithoutOpeningSocketOrIdentity() {
        let store = FakeOpenClawStore()
        var socketsCreated = 0
        let model = AssistantChatModel(store: store, gateway: OpenClawGatewayClient(makeSocket: { _ in
            socketsCreated += 1
            return FakeOpenClawSocket()
        }))
        model.refreshGatewayDetails()
        XCTAssertTrue(model.hasSavedGateway)
        XCTAssertEqual(model.gatewayAddress, "wss://gateway.example")
        XCTAssertEqual(model.gatewayHost, "gateway.example")
        XCTAssertNil(model.deviceID)
        XCTAssertEqual(store.reads, 1, "Read the saved credential only; don't create a device identity.")
        XCTAssertEqual(socketsCreated, 0)
    }

    func testForgetImmediatelyMakesConnectGatewayAvailable() {
        let store = FakeOpenClawStore()
        let model = AssistantChatModel(store: store)
        model.refreshGatewayDetails()
        model.forget()
        XCTAssertNil(store.saved)
        XCTAssertFalse(model.hasSavedGateway)
        XCTAssertNil(model.gatewayAddress)
        XCTAssertNil(model.gatewayHost)
        XCTAssertEqual(model.state, .needsPairing)
    }

    func testMovePreservesCredentialAndIdentityAndDoesNotSendACommand() async throws {
        let store = FakeOpenClawStore()
        let credential = try XCTUnwrap(store.saved)
        var endpoints: [URL] = []
        var sockets: [FakeOpenClawSocket] = []
        let model = AssistantChatModel(store: store, gateway: OpenClawGatewayClient(makeSocket: { url in
            endpoints.append(url)
            let socket = FakeOpenClawSocket()
            socket.respondToChat()
            sockets.append(socket)
            return socket
        }))
        defer { model.pause() }
        model.activate(configuration: AssistantConfiguration())
        for _ in 0..<300 where model.state != .connected { await Task.yield() }
        XCTAssertEqual(model.state, .connected)
        try model.changeGatewayAddress("https://moved.example/openclaw")
        for _ in 0..<300 where model.state != .connected { await Task.yield() }
        XCTAssertEqual(model.state, .connected)
        XCTAssertEqual(endpoints.map(\.absoluteString), ["wss://gateway.example", "wss://moved.example/openclaw"])
        XCTAssertEqual(model.gatewayAddress, "wss://moved.example/openclaw")
        XCTAssertEqual(store.saved?.token, credential.token)
        XCTAssertEqual(store.saved?.scopes, credential.scopes)
        let handshakes = sockets.compactMap { $0.sent.first?["params"] as? [String: Any] }
        XCTAssertEqual(handshakes.count, 2)
        XCTAssertEqual((handshakes[0]["device"] as? [String: Any])?["id"] as? String,
                       (handshakes[1]["device"] as? [String: Any])?["id"] as? String)
        XCTAssertFalse(sockets.flatMap(\.sent).contains { $0["method"] as? String == "chat.send" })
        XCTAssertNil(model.directive)
    }

    func testInvalidAddressDoesNotReplaceExistingPairing() throws {
        let store = FakeOpenClawStore()
        let original = store.saved
        let model = AssistantChatModel(store: store)
        model.refreshGatewayDetails()
        XCTAssertThrowsError(try model.changeGatewayAddress("http://unsafe.example"))
        XCTAssertEqual(store.saved, original)
        XCTAssertEqual(model.gatewayAddress, original?.gatewayURL)
    }

    func testUnpairedAddressEntryRequiresNewPairingRatherThanInventingACredential() {
        let store = FakeOpenClawStore()
        store.saved = nil
        let model = AssistantChatModel(store: store)
        XCTAssertThrowsError(try model.changeGatewayAddress("new.example")) {
            XCTAssertEqual($0 as? OpenClawError, .gatewayNotPaired)
        }
        XCTAssertNil(store.saved)
    }

    func testKeychainFailurePreservesWorkingConnectionAndAddress() async throws {
        let store = FailingSaveGatewayStore()
        let socket = FakeOpenClawSocket()
        socket.respondToChat()
        // Avoid the simulated hello issuing a rotated token on initial connect.
        let responder = socket.onSend
        socket.onSend = { frame in
            if frame["method"] as? String == "connect" {
                socket.reply(frame, payload: ["type": "hello-ok", "protocol": 4, "policy": ["tickIntervalMs": 30_000]])
            } else { responder?(frame) }
        }
        let model = AssistantChatModel(store: store, gateway: OpenClawGatewayClient(makeSocket: { _ in socket }))
        defer { model.pause() }
        model.activate(configuration: AssistantConfiguration())
        for _ in 0..<300 where model.state != .connected { await Task.yield() }
        XCTAssertThrowsError(try model.changeGatewayAddress("new.example"))
        XCTAssertEqual(model.state, .connected)
        XCTAssertEqual(model.gatewayAddress, "wss://gateway.example")
        XCTAssertEqual(store.saved.gatewayURL, "wss://gateway.example")
    }

    func testGatewayChangesCannotInterruptAnActiveDirective() async throws {
        let store = FakeOpenClawStore()
        let socket = FakeOpenClawSocket()
        socket.respondToChat()
        let model = AssistantChatModel(store: store, gateway: OpenClawGatewayClient(makeSocket: { _ in socket }))
        defer { model.pause() }
        model.activate(configuration: AssistantConfiguration())
        for _ in 0..<300 where model.state != .connected { await Task.yield() }
        model.send("Test directive")
        let run = model.activeRunID
        XCTAssertNotNil(run)
        XCTAssertThrowsError(try model.changeGatewayAddress("new.example")) {
            XCTAssertEqual($0 as? OpenClawError, .directiveInProgress)
        }
        XCTAssertThrowsError(try model.pair("invalid-code")) {
            XCTAssertEqual($0 as? OpenClawError, .directiveInProgress)
        }
        model.forget()
        XCTAssertNotNil(store.saved)
        XCTAssertEqual(model.activeRunID, run)
        XCTAssertEqual(model.directive?.status, .running)
    }
}

@MainActor
private final class FailingSaveGatewayStore: OpenClawCredentialStoring {
    var saved = OpenClawCredential(gatewayURL: "wss://gateway.example", token: "test-token", scopes: OpenClawCredential.connectionScopes)
    private let key = try! OpenClawIdentity()
    func identity() throws -> OpenClawIdentity { key }
    func credential() throws -> OpenClawCredential? { saved }
    func save(_ credential: OpenClawCredential) throws { throw OpenClawError.keychain }
    func forget() throws { throw OpenClawError.keychain }
}

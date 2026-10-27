import XCTest
@testable import Hassonic

@MainActor
final class AssistantIdentityNameTests: XCTestCase {
    func testNameIsScopedToHassonicAndFallsBackForInvalidResponses() {
        XCTAssertEqual(AssistantChatModel.displayName(from: ["agentId": "hassonic", "name": " Octo "]), "Octo")
        for identity: [String: Any]? in [nil, [:], ["agentId": "family", "name": "Octo"],
                                       ["agentId": "hassonic", "name": "  "],
                                       ["agentId": "hassonic", "name": "bad\nname"],
                                       ["agentId": "hassonic", "name": String(repeating: "x", count: 81)]] {
            XCTAssertEqual(AssistantChatModel.displayName(from: identity), "OpenClaw")
        }
    }

    func testFetchesNameAfterConnectionAndForgetClearsIt() async throws {
        let socket = FakeOpenClawSocket()
        socket.respondToChat()
        let original = socket.onSend
        socket.onSend = { frame in
            if frame["method"] as? String == "agent.identity.get" {
                let params = frame["params"] as? [String: Any]
                XCTAssertEqual(params?["agentId"] as? String, "hassonic")
                XCTAssertEqual(params?["sessionKey"] as? String, "agent:hassonic:main")
                socket.reply(frame, payload: ["agentId": "hassonic", "name": "Octo"])
            } else { original?(frame) }
        }
        let model = AssistantChatModel(store: FakeOpenClawStore(), gateway: OpenClawGatewayClient(makeSocket: { _ in socket }))
        defer { model.pause() }
        XCTAssertEqual(model.assistantName, "OpenClaw")
        model.activate(configuration: AssistantConfiguration())
        for _ in 0..<500 where model.assistantName != "Octo" { await Task.yield() }
        XCTAssertEqual(model.state, .connected)
        XCTAssertEqual(model.assistantName, "Octo")
        XCTAssertEqual(model.displayText("OpenClaw is working on it…"), "Octo is working on it…")
        XCTAssertFalse(socket.sent.contains { $0["method"] as? String == "chat.send" })
        model.forget()
        XCTAssertEqual(model.assistantName, "OpenClaw")
    }

    func testRejectedIdentityLookupDoesNotPreventCommands() async throws {
        let socket = FakeOpenClawSocket()
        socket.respondToChat()
        let original = socket.onSend
        socket.onSend = { frame in
            if frame["method"] as? String == "agent.identity.get" {
                socket.emit(["type": "res", "id": frame["id"]!, "ok": false,
                             "error": ["code": "INVALID_REQUEST", "message": "missing scope"]])
            } else { original?(frame) }
        }
        let model = AssistantChatModel(store: FakeOpenClawStore(), gateway: OpenClawGatewayClient(makeSocket: { _ in socket }))
        defer { model.pause() }
        model.activate(configuration: AssistantConfiguration())
        for _ in 0..<500 where model.state != .connected { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(model.assistantName, "OpenClaw")
        XCTAssertEqual(model.state, .connected)
        XCTAssertNil(model.errorMessage)
        model.send("Test directive")
        for _ in 0..<500 where !socket.sent.contains(where: { $0["method"] as? String == "chat.send" }) { await Task.yield() }
        XCTAssertTrue(socket.sent.contains { $0["method"] as? String == "chat.send" })
    }
}

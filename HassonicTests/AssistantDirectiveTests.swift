import XCTest
@testable import Hassonic

@MainActor
final class AssistantDirectiveTests: XCTestCase {
    private func connectedModel(socket: FakeOpenClawSocket) async -> AssistantChatModel {
        let model = AssistantChatModel(store: FakeOpenClawStore(), gateway: OpenClawGatewayClient(makeSocket: { _ in socket }))
        model.activate(configuration: AssistantConfiguration())
        for _ in 0..<300 where model.state != .connected { await Task.yield() }
        XCTAssertEqual(model.state, .connected)
        return model
    }

    private func event(run: String, state: String, seq: Int = 1, extra: [String: Any] = [:]) -> [String: Any] {
        ["type": "event", "event": "chat", "payload": [
            "runId": run, "sessionKey": "agent:hassonic:main", "agentId": "hassonic", "state": state, "seq": seq
        ].merging(extra) { _, new in new }]
    }

    func testProgressAndResultOnlyBelongToSubmittedDirective() async throws {
        let socket = FakeOpenClawSocket()
        socket.respondToChat()
        let model = await connectedModel(socket: socket)
        defer { model.pause() }
        socket.emit(event(run: "another-device", state: "final", extra: ["message": ["content": "Private unrelated reply"]]))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(model.directive)
        model.send("Turn off the downstairs lights")
        let run = try XCTUnwrap(model.directive?.runID)
        socket.emit(event(run: run, state: "delta", extra: ["deltaText": "Turning off the lights…"]))
        for _ in 0..<300 where model.directive?.response.isEmpty == true { await Task.yield() }
        XCTAssertEqual(model.directive?.status, .running)
        XCTAssertEqual(model.directive?.response, "Turning off the lights…")
        socket.emit(event(run: run, state: "final", seq: 2, extra: ["message": ["content": "The downstairs lights are off."]]))
        for _ in 0..<300 where model.directive?.status == .running { await Task.yield() }
        XCTAssertEqual(model.directive?.status, .completed)
        XCTAssertEqual(model.directive?.response, "The downstairs lights are off.")
        XCTAssertNil(model.activeRunID)
        model.clearDirective()
        XCTAssertNil(model.directive)
        XCTAssertTrue(model.transcript.messages.isEmpty)
        XCTAssertFalse(socket.sent.contains { $0["method"] as? String == "chat.history" })
    }

    func testServerAssignedRunCanFinishBeforeSendAcknowledgement() async throws {
        let socket = FakeOpenClawSocket()
        socket.respondToChat()
        let defaultResponder = socket.onSend
        socket.onSend = { frame in
            if frame["method"] as? String == "chat.send" {
                socket.emit(self.event(run: "server-run", state: "delta", extra: ["deltaText": "Working"]))
                socket.emit(self.event(run: "server-run", state: "final", seq: 2, extra: ["message": ["content": "Done"]]))
                socket.reply(frame, payload: ["runId": "server-run"])
            } else { defaultResponder?(frame) }
        }
        let model = await connectedModel(socket: socket)
        defer { model.pause() }
        model.send("Test directive")
        for _ in 0..<300 where model.directive?.status == .running { await Task.yield() }
        XCTAssertEqual(model.directive?.runID, "server-run")
        XCTAssertEqual(model.directive?.status, .completed)
        XCTAssertEqual(model.directive?.response, "Done")
        XCTAssertNil(model.activeRunID)
    }

    func testInterruptionPreservesDirectiveWithoutResendingIt() async throws {
        let socket = FakeOpenClawSocket()
        socket.respondToChat()
        let model = await connectedModel(socket: socket)
        model.send("Test directive")
        for _ in 0..<100 { await Task.yield() }
        model.pause()
        XCTAssertEqual(model.directive?.status, .interrupted)
        XCTAssertEqual(model.directive?.text, "Test directive")
        XCTAssertEqual(socket.sent.filter { $0["method"] as? String == "chat.send" }.count, 1)
        XCTAssertTrue(model.errorMessage?.contains("has not been sent again") == true)
    }

    func testStopCancelsTheCurrentDirective() async throws {
        let socket = FakeOpenClawSocket()
        socket.respondToChat()
        let model = await connectedModel(socket: socket)
        defer { model.pause() }
        model.send("Test directive")
        for _ in 0..<100 { await Task.yield() }
        await model.stop()
        XCTAssertEqual(model.directive?.status, .cancelled)
        XCTAssertEqual(socket.sent.last?["method"] as? String, "chat.abort")
        XCTAssertEqual((socket.sent.last?["params"] as? [String: Any])?["agentId"] as? String, "hassonic")
    }

    func testAssistantSheetDoesNotChangeThePage() throws {
        let router = AppRouter()
        router.setAssistantEnabled(true)
        for tab: AppTab in [.music, .dashboard("home"), .dashboard("remote"), .dashboard("security")] {
            router.navigate(to: .tab(tab))
            router.handle(url: try XCTUnwrap(URL(string: "hassonic://assistant")))
            XCTAssertEqual(router.presentedSheet, .assistant)
            XCTAssertEqual(router.selectedTab, tab)
            router.presentedSheet = nil
        }
    }
}

@MainActor
final class DirectiveVoicePermissionTests: XCTestCase {
    func testReleasingDuringPermissionPromptDoesNotOpenMicrophoneLater() async {
        var authorization: CheckedContinuation<Bool, Never>?
        let listener = VoiceCommandListener(authorize: { await withCheckedContinuation { authorization = $0 } })
        var delivered = false
        let recording = Task { await listener.start(mode: .hold) { _ in delivered = true } }
        for _ in 0..<100 where authorization == nil { await Task.yield() }
        XCTAssertNotNil(authorization)
        listener.stop()
        authorization?.resume(returning: true)
        await recording.value
        XCTAssertEqual(listener.state, .idle)
        XCTAssertFalse(delivered)
    }

    func testDeniedPermissionDoesNotRecordOrSendAnything() async {
        let listener = VoiceCommandListener(authorize: { false })
        var delivered = false
        await listener.start(mode: .hold) { _ in delivered = true }
        XCTAssertEqual(listener.state, .denied)
        XCTAssertFalse(delivered)
    }
}

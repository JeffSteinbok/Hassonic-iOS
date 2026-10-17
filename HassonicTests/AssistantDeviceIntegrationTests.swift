import XCTest
@testable import Hassonic

/// Opt-in physical-device smoke test. No credentials or gateway address are in the repo.
/// Supply a fresh limited setup code as Documents/openclaw-assistant-setup-code.txt
/// in the Dev app container, then run this test explicitly on that device.
@MainActor
final class AssistantDeviceIntegrationTests: XCTestCase {
    func testLiveDevicePairingAndChat() async throws {
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let setupURL = documents.appendingPathComponent("openclaw-assistant-setup-code.txt")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: setupURL.path), "Live device pairing is opt-in; no setup code supplied.")
        let setupCode = try String(contentsOf: setupURL, encoding: .utf8)
        // Consume the transient bootstrap artifact immediately. Only Keychain survives.
        try FileManager.default.removeItem(at: setupURL)
        let configurationDeadline = Date().addingTimeInterval(30)
        while Date() < configurationDeadline, AppConfigurationLoader.launchConfiguration()?.assistant == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        let configuration = try XCTUnwrap(AppConfigurationLoader.launchConfiguration()?.assistant,
                                          "Enable Assistant in the device's loaded household configuration first.")
        let model = AssistantChatModel()
        defer { model.pause() }
        model.activate(configuration: configuration)
        try model.pair(setupCode)
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, model.state != .connected || model.isLoadingHistory {
            if model.state == .needsPairing, let error = model.errorMessage { XCTFail(error); return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(model.state, .connected, "The phone must connect using its own signed device identity.")
        guard model.state == .connected else { return }
        let before = model.transcript.messages.count
        model.send("Connectivity test from Hassonic on this iPhone. Reply exactly HASSONIC_DEVICE_OK. Do not call any tools.")
        let replyDeadline = Date().addingTimeInterval(90)
        while Date() < replyDeadline {
            let replies = model.transcript.messages.dropFirst(before).filter { !$0.isUser }
            if replies.contains(where: { $0.text.contains("HASSONIC_DEVICE_OK") }), model.activeRunID == nil {
                XCTAssertNotNil(try OpenClawCredentialStore().credential(), "Keep the device credential for normal app use.")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("The phone did not receive the expected reply before the deadline.")
    }
}

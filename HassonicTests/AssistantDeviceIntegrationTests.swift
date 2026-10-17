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
        let reuseURL = documents.appendingPathComponent("openclaw-assistant-live-test.txt")
        let hasSetup = FileManager.default.fileExists(atPath: setupURL.path)
        let reuseCredential = FileManager.default.fileExists(atPath: reuseURL.path)
        try XCTSkipUnless(hasSetup || reuseCredential, "Live device test is opt-in; no setup code or opt-in marker supplied.")
        let setupCode = hasSetup ? try String(contentsOf: setupURL, encoding: .utf8) : nil
        // Consume the transient bootstrap artifact immediately. Only Keychain survives.
        if hasSetup { try FileManager.default.removeItem(at: setupURL) }
        if reuseCredential { try FileManager.default.removeItem(at: reuseURL) }
        let configurationDeadline = Date().addingTimeInterval(30)
        while Date() < configurationDeadline, AppConfigurationLoader.launchConfiguration()?.assistant == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        let configuration = try XCTUnwrap(AppConfigurationLoader.launchConfiguration()?.assistant,
                                          "Enable Assistant in the device's loaded household configuration first.")
        let model = AssistantChatModel()
        defer { model.pause() }
        model.activate(configuration: configuration)
        if let setupCode { try model.pair(setupCode) }
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, model.state != .connected {
            if model.state == .needsPairing, let error = model.errorMessage { XCTFail(error); return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(model.state, .connected, "The phone must connect using its own signed device identity.")
        guard model.state == .connected else { return }
        model.send("Connectivity test from Hassonic on this iPhone. Reply exactly HASSONIC_DEVICE_OK. Do not call any tools.")
        let replyDeadline = Date().addingTimeInterval(90)
        while Date() < replyDeadline {
            if model.directive?.status == .failed {
                XCTFail(model.directive?.response ?? model.errorMessage ?? "The directive failed.")
                return
            }
            if model.directive?.response.contains("HASSONIC_DEVICE_OK") == true, model.directive?.status == .completed {
                XCTAssertNotNil(try OpenClawCredentialStore().credential(), "Keep the device credential for normal app use.")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("The phone did not receive the expected reply before the deadline.")
    }
}

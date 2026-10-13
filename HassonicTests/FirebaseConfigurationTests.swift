import XCTest
@testable import Hassonic

final class FirebaseConfigurationTests: XCTestCase {
    func testAcceptsValidConfiguration() {
        XCTAssertTrue(FirebaseConfiguration.isValid([
            "GOOGLE_APP_ID": "1:1234567890:ios:abcdef1234567890",
            "GCM_SENDER_ID": "1234567890",
            "PROJECT_ID": "sterling-home",
            "API_KEY": "test-api-key",
        ]))
    }

    func testRejectsPlaceholderConfiguration() {
        XCTAssertFalse(FirebaseConfiguration.isValid([
            "GOOGLE_APP_ID": "REPLACE_ME",
            "GCM_SENDER_ID": "REPLACE_ME",
            "PROJECT_ID": "REPLACE_ME",
            "API_KEY": "REPLACE_ME",
        ]))
    }

    func testRejectsMalformedGoogleAppID() {
        XCTAssertFalse(FirebaseConfiguration.isValid([
            "GOOGLE_APP_ID": "not-an-app-id",
            "GCM_SENDER_ID": "1234567890",
            "PROJECT_ID": "sterling-home",
            "API_KEY": "test-api-key",
        ]))
    }
}

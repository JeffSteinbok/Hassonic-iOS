import XCTest
@testable import Hassonic

final class ConnectionURLResolverTests: XCTestCase {

    func testUsesInternalURLWhenSSIDMatchesTrusted() async {
        var probeCalled = false
        let result = await ConnectionURLResolver.resolve(
            externalURLString: "https://external.example.com",
            internalURLString: "http://homeassistant.local:8123",
            trustedSSID: "HomeWiFi",
            probe: { _ in
                probeCalled = true
                return false
            },
            currentSSID: { "HomeWiFi" }
        )
        XCTAssertEqual(result, "http://homeassistant.local:8123")
        XCTAssertFalse(probeCalled, "a trusted SSID match should skip the reachability probe entirely")
    }

    func testFallsBackToProbeWhenSSIDUnknown() async {
        let result = await ConnectionURLResolver.resolve(
            externalURLString: "https://external.example.com",
            internalURLString: "http://homeassistant.local:8123",
            trustedSSID: "HomeWiFi",
            probe: { _ in true },
            currentSSID: { nil }
        )
        XCTAssertEqual(result, "http://homeassistant.local:8123")
    }

    func testFallsBackToProbeWhenSSIDDoesNotMatchTrusted() async {
        let result = await ConnectionURLResolver.resolve(
            externalURLString: "https://external.example.com",
            internalURLString: "http://homeassistant.local:8123",
            trustedSSID: "HomeWiFi",
            probe: { _ in false },
            currentSSID: { "CoffeeShop" }
        )
        XCTAssertEqual(result, "https://external.example.com")
    }

    func testLearnsCurrentSSIDWhenProbeSucceedsWithNoTrustedSSIDYet() async {
        var learnedSSID: String?
        let result = await ConnectionURLResolver.resolve(
            externalURLString: "https://external.example.com",
            internalURLString: "http://homeassistant.local:8123",
            trustedSSID: nil,
            probe: { _ in true },
            currentSSID: { "HomeWiFi" },
            onLearnTrustedSSID: { learnedSSID = $0 }
        )
        XCTAssertEqual(result, "http://homeassistant.local:8123")
        XCTAssertEqual(learnedSSID, "HomeWiFi")
    }

    func testDoesNotRelearnSSIDWhenAlreadyMatchedViaProbeFallback() async {
        var learnCallCount = 0
        _ = await ConnectionURLResolver.resolve(
            externalURLString: "https://external.example.com",
            internalURLString: "http://homeassistant.local:8123",
            trustedSSID: "HomeWiFi",
            probe: { _ in true },
            currentSSID: { nil },
            onLearnTrustedSSID: { _ in learnCallCount += 1 }
        )
        XCTAssertEqual(learnCallCount, 0, "nil SSID shouldn't overwrite an already-trusted one")
    }

    func testUsesExternalURLWhenInternalUnreachable() async {
        let result = await ConnectionURLResolver.resolve(
            externalURLString: "https://external.example.com",
            internalURLString: "http://homeassistant.local:8123",
            trustedSSID: nil,
            probe: { _ in false },
            currentSSID: { nil }
        )
        XCTAssertEqual(result, "https://external.example.com")
    }

    func testUsesExternalURLWhenNoInternalURLConfigured() async {
        var probeCalled = false
        let result = await ConnectionURLResolver.resolve(
            externalURLString: "https://external.example.com",
            internalURLString: "",
            trustedSSID: nil,
            probe: { _ in
                probeCalled = true
                return true
            },
            currentSSID: { nil }
        )
        XCTAssertEqual(result, "https://external.example.com")
        XCTAssertFalse(probeCalled, "shouldn't probe at all when no internal URL is configured")
    }

    func testProbesTheInternalURLSpecifically() async {
        var probedURL: URL?
        _ = await ConnectionURLResolver.resolve(
            externalURLString: "https://external.example.com",
            internalURLString: "http://homeassistant.local:8123",
            trustedSSID: nil,
            probe: { url in
                probedURL = url
                return true
            },
            currentSSID: { nil }
        )
        XCTAssertEqual(probedURL, URL(string: "http://homeassistant.local:8123"))
    }
}

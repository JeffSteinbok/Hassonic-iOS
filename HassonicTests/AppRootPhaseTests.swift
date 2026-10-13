import XCTest
@testable import Hassonic

final class AppRootPhaseTests: XCTestCase {

    private func phase(
        saved: Bool = true,
        state: HAConnectionState,
        willRetry: Bool = true,
        isStarting: Bool = false,
        hasConnected: Bool = false,
        isOverdue: Bool = false
    ) -> AppRootPhase {
        AppRootPhase.resolve(
            hasSavedConnection: saved,
            connectionState: state,
            willRetry: willRetry,
            isStarting: isStarting,
            hasConnected: hasConnected,
            isOverdue: isOverdue
        )
    }

    func testNoSavedConnectionShowsWelcome() {
        XCTAssertEqual(phase(saved: false, state: .disconnected, willRetry: false, isStarting: true), .welcome)
    }

    func testLaunchShowsSplashBeforeTheFirstAttempt() {
        XCTAssertEqual(phase(state: .disconnected, willRetry: false, isStarting: true), .connecting)
    }

    func testConnectingShowsSplash() {
        XCTAssertEqual(phase(state: .connecting), .connecting)
        XCTAssertEqual(phase(state: .authenticating), .connecting)
    }

    func testConnectedShowsTabs() {
        XCTAssertEqual(phase(state: .connected), .connected)
    }

    /// The client retries socket errors itself; a blip shouldn't flash the
    /// failure screen.
    func testRetryingFailureKeepsTheSplash() {
        XCTAssertEqual(phase(state: .failed("The network connection was lost.")), .connecting)
    }

    func testFailureWithNoRetryShowsFailure() {
        XCTAssertEqual(
            phase(state: .failed("Authentication failed. Please log in again."), willRetry: false),
            .failed("Authentication failed. Please log in again.")
        )
    }

    func testOverdueShowsFailureWithTheLastError() {
        XCTAssertEqual(
            phase(state: .failed("The request timed out."), isOverdue: true),
            .failed("The request timed out.")
        )
        XCTAssertEqual(phase(state: .connecting, isOverdue: true), .failed("Home Assistant isn't responding."))
    }

    func testReconnectKeepsTheTabsUp() {
        XCTAssertEqual(phase(state: .connecting, hasConnected: true), .connected)
        XCTAssertEqual(phase(state: .failed("lost"), hasConnected: true), .connected)
    }

    func testLongOutageAfterConnectingStillShowsFailure() {
        XCTAssertEqual(phase(state: .connecting, hasConnected: true, isOverdue: true), .failed("Home Assistant isn't responding."))
    }

    func testManualDisconnectShowsFailure() {
        XCTAssertEqual(
            phase(state: .disconnected, willRetry: false, hasConnected: true),
            .failed("Not connected to Home Assistant.")
        )
    }
}

import XCTest
@testable import Hassonic

final class NowPlayingDestinationLabelTests: XCTestCase {
    func testInactiveDestinationShowsChooseSpeakers() {
        XCTAssertEqual(nowPlayingDestinationLabel(activeSource: nil), "Choose speakers")
    }

    func testActiveDestinationShowsPlayingOn() {
        XCTAssertEqual(nowPlayingDestinationLabel(activeSource: "Inside"), "Playing on")
    }
}

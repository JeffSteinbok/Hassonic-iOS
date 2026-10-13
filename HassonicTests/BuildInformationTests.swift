import XCTest
@testable import Hassonic

final class BuildInformationTests: XCTestCase {
    func testReadsBuildMetadataFromInfoDictionary() {
        let build = BuildInformation(infoDictionary: [
            "CFBundleShortVersionString": "2.3",
            "CFBundleVersion": "47",
            "BuildGitShortSHA": "abc12345",
            "BuildTimestamp": "2026-08-02T04:00:00Z",
            "BuildConfiguration": "Debug",
        ])

        XCTAssertEqual(build.versionAndBuild, "2.3 (47)")
        XCTAssertEqual(build.revision, "abc12345")
        XCTAssertEqual(build.timestamp, "2026-08-02T04:00:00Z")
        XCTAssertEqual(build.configuration, "Debug")
    }

    func testMissingBuildMetadataUsesClearFallbacks() {
        let build = BuildInformation(infoDictionary: [:])

        XCTAssertEqual(build.versionAndBuild, "unknown (unknown)")
        XCTAssertEqual(build.revision, "unknown")
        XCTAssertEqual(build.timestamp, "unknown")
        XCTAssertEqual(build.configuration, "unknown")
    }
}

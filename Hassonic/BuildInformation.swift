import Foundation

struct BuildInformation: Equatable {
    let marketingVersion: String
    let buildNumber: String
    let revision: String
    let timestamp: String
    let configuration: String

    static var current: BuildInformation {
        BuildInformation(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    init(infoDictionary: [String: Any]) {
        marketingVersion = Self.stringValue(
            for: "CFBundleShortVersionString",
            in: infoDictionary
        )
        buildNumber = Self.stringValue(for: "CFBundleVersion", in: infoDictionary)
        revision = Self.stringValue(for: "BuildGitShortSHA", in: infoDictionary)
        timestamp = Self.stringValue(for: "BuildTimestamp", in: infoDictionary)
        configuration = Self.stringValue(for: "BuildConfiguration", in: infoDictionary)
    }

    var versionAndBuild: String {
        "\(marketingVersion) (\(buildNumber))"
    }

    private static func stringValue(for key: String, in dictionary: [String: Any]) -> String {
        guard let value = dictionary[key] as? String, !value.isEmpty else {
            return "unknown"
        }
        return value
    }
}

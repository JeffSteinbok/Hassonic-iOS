// swift-tools-version:5.9

import PackageDescription

// DashboardConfiguration.swift is symlinked in from the app target so the
// validator can never drift from the schema the app actually enforces.
let package = Package(
    name: "DashboardValidator",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3")
    ],
    targets: [
        .executableTarget(
            name: "DashboardValidator",
            dependencies: ["Yams"]
        )
    ]
)

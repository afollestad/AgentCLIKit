// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentCLIKit",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "AgentCLIKit",
            targets: ["AgentCLIKit"]
        ),
        .executable(
            name: "AgentCLIKitDemo",
            targets: ["AgentCLIKitDemo"]
        )
    ],
    targets: [
        .target(
            name: "AgentCLIKit",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "AgentCLIKitDemoSupport",
            dependencies: ["AgentCLIKit"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "AgentCLIKitDemo",
            dependencies: ["AgentCLIKit", "AgentCLIKitDemoSupport"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "AgentCLIKitTests",
            dependencies: ["AgentCLIKit"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)

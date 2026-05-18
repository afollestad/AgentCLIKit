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
        )
    ],
    targets: [
        .target(
            name: "AgentCLIKit",
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

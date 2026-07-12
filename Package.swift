// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "AgentCLIKit",
    platforms: [
        .macOS("15.0")
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
    dependencies: [
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            exact: "0.12.1"
        )
    ],
    targets: [
        .target(
            name: "AgentCLIKit",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ],
            exclude: [
                "Claude/AGENTS.md",
                "Claude/CLAUDE.md",
                "Claude/Hooks/AGENTS.md",
                "Claude/Hooks/CLAUDE.md",
                "Codex/AGENTS.md",
                "Codex/CLAUDE.md",
                "MCP/AGENTS.md",
                "MCP/CLAUDE.md",
                "Runtime/AGENTS.md",
                "Runtime/CLAUDE.md"
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "AgentCLIKitDemo",
            dependencies: ["AgentCLIKit"],
            exclude: [
                "AGENTS.md",
                "CLAUDE.md",
                "Interactions/AGENTS.md",
                "Interactions/CLAUDE.md"
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "AgentCLIKitTests",
            dependencies: ["AgentCLIKit"],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)

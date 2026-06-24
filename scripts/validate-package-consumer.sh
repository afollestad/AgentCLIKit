#!/bin/bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
package_root=$(mktemp -d -t agentclikit-consumer.XXXXXX)
cache_root=$(mktemp -d -t agentclikit-consumer-cache.XXXXXX)
trap 'rm -rf "$package_root" "$cache_root"' EXIT

cat >"$package_root/Package.swift" <<EOF
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentCLIKitConsumer",
    platforms: [
        .macOS("15.0")
    ],
    dependencies: [
        .package(path: "$repo_root")
    ],
    targets: [
        .executableTarget(
            name: "AgentCLIKitConsumer",
            dependencies: [
                .product(name: "AgentCLIKit", package: "AgentCLIKit")
            ]
        )
    ]
)
EOF

mkdir -p "$package_root/Sources/AgentCLIKitConsumer"
cat >"$package_root/Sources/AgentCLIKitConsumer/main.swift" <<'EOF'
import AgentCLIKit
import Foundation

let runtime = DefaultAgentRuntime(adapters: [ClaudeProviderAdapter()])
let config = AgentSpawnConfig(
    providerId: .claude,
    workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
    permissionMode: "plan"
)

print("\(type(of: runtime)) \(config.providerId.rawValue)")
EOF

swift build \
  --package-path "$package_root" \
  --scratch-path "$cache_root/build" \
  --cache-path "$cache_root/cache"

swift build \
  --package-path "$repo_root" \
  --scratch-path "$cache_root/demo-build" \
  --cache-path "$cache_root/demo-cache" \
  --product AgentCLIKitDemo

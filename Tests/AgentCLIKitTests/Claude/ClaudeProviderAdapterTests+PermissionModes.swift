import Foundation
import XCTest

@testable import AgentCLIKit

extension ClaudeProviderAdapterTests {
    func testLaunchConfigurationUnlocksBypassPermissionsMode() async throws {
        let adapter = ClaudeProviderAdapter(executablePath: "/opt/homebrew/bin/claude")
        let config = AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            permissionMode: "bypassPermissions",
            collaborationMode: .default
        )

        let launch = try await adapter.makeLaunchConfiguration(spawnConfig: config, resumedSession: nil)
        let permissionModeIndex = try XCTUnwrap(launch.arguments.firstIndex(of: "--permission-mode"))

        XCTAssertEqual(launch.arguments[permissionModeIndex + 1], "bypassPermissions")
        XCTAssertTrue(launch.arguments.contains("--allow-dangerously-skip-permissions"))
        XCTAssertFalse(launch.arguments.contains("--dangerously-skip-permissions"))
    }

    func testLaunchConfigurationCanonicalizesDontAskPermissionMode() async throws {
        let adapter = ClaudeProviderAdapter(executablePath: "/opt/homebrew/bin/claude")
        let config = AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            permissionMode: "dontAsk",
            collaborationMode: .default
        )

        let launch = try await adapter.makeLaunchConfiguration(spawnConfig: config, resumedSession: nil)
        let permissionModeIndex = try XCTUnwrap(launch.arguments.firstIndex(of: "--permission-mode"))

        XCTAssertEqual(launch.arguments[permissionModeIndex + 1], "bypassPermissions")
        XCTAssertTrue(launch.arguments.contains("--allow-dangerously-skip-permissions"))
    }
}

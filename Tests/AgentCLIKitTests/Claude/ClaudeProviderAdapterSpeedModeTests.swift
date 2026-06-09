import XCTest

@testable import AgentCLIKit

final class ClaudeProviderAdapterSpeedModeTests: XCTestCase {
    func testClaudeDefinitionDoesNotSupportSpeedMode() {
        XCTAssertFalse(ClaudeProviderAdapter().definition.capabilities.supportsSpeedMode)
    }

    func testLaunchConfigurationRejectsFastSpeedModeWithoutBareMode() async throws {
        let adapter = ClaudeProviderAdapter(executablePath: "/opt/homebrew/bin/claude")
        let standardConfig = AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            speedMode: .standard
        )
        let fastConfig = AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            speedMode: .fast
        )

        let standardLaunch = try await adapter.makeLaunchConfiguration(spawnConfig: standardConfig, resumedSession: nil)
        XCTAssertFalse(standardLaunch.arguments.contains("--bare"))

        do {
            _ = try await adapter.makeLaunchConfiguration(spawnConfig: fastConfig, resumedSession: nil)
            XCTFail("Expected Claude fast speed mode to be rejected.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error.code, .unsupportedCapability)
            XCTAssertEqual(error.metadata["provider_id"], .string("claude"))
            XCTAssertEqual(error.metadata["capability"], .string("fast mode"))
        }
    }
}

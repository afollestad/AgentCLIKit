import XCTest

@testable import AgentCLIKit

final class ClaudeHarnessAdapterSpeedModeTests: XCTestCase {
    func testClaudeDefinitionDoesNotSupportSpeedMode() {
        XCTAssertFalse(ClaudeHarnessAdapter().definition.capabilities.supportsSpeedMode)
    }

    func testLaunchConfigurationRejectsFastSpeedModeWithoutBareMode() async throws {
        let adapter = ClaudeHarnessAdapter(executablePath: "/opt/homebrew/bin/claude")
        let standardConfig = AgentSpawnConfig(
            harnessId: .claude,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            speedMode: .standard
        )
        let fastConfig = AgentSpawnConfig(
            harnessId: .claude,
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

import XCTest

@testable import AgentCLIKit

final class ClaudeIntegrationIsolationTests: XCTestCase {
    func testClaudeSupportsNativeIntegrationIsolationOnly() {
        XCTAssertEqual(ClaudeHarnessAdapter().definition.capabilities.supportedIntegrationIsolation, [.nativeIntegrations])
    }

    func testNativeIntegrationIsolationRestrictsMCPToLaunchConfig() async throws {
        let adapter = ClaudeHarnessAdapter(executablePath: "/opt/homebrew/bin/claude")
        let workingDirectory = URL(fileURLWithPath: "/tmp/project")

        let isolated = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(harnessId: .claude, workingDirectory: workingDirectory, integrationIsolation: .nativeIntegrations),
            resumedSession: nil
        )
        let unisolated = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(harnessId: .claude, workingDirectory: workingDirectory),
            resumedSession: nil
        )

        XCTAssertTrue(isolated.arguments.contains("--strict-mcp-config"))
        XCTAssertFalse(unisolated.arguments.contains("--strict-mcp-config"))
    }
}

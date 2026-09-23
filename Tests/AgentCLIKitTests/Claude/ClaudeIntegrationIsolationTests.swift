import XCTest

@testable import AgentCLIKit

final class ClaudeIntegrationIsolationTests: XCTestCase {
    func testClaudeSupportsBothIsolationOptions() {
        XCTAssertEqual(
            ClaudeHarnessAdapter().definition.capabilities.supportedIntegrationIsolation, [.nativeIntegrations, .shellNetwork]
        )
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

    /// Without hook settings this inline flag is the only sandbox; with them, the hook file repeats it last.
    func testShellNetworkIsolationPassesANetworkLessSandbox() async throws {
        let adapter = ClaudeHarnessAdapter(executablePath: "/opt/homebrew/bin/claude")
        let launch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                harnessId: .claude, workingDirectory: URL(fileURLWithPath: "/tmp/project"), integrationIsolation: .shellNetwork
            ),
            resumedSession: nil
        )

        let index = try XCTUnwrap(launch.arguments.firstIndex(of: "--settings"))
        let settings = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(launch.arguments[index + 1].utf8)) as? [String: Any]
        )
        let sandbox = try XCTUnwrap(settings["sandbox"] as? [String: Any])
        XCTAssertEqual(sandbox["enabled"] as? Bool, true)
        XCTAssertEqual(sandbox["failIfUnavailable"] as? Bool, true)
        let network = try XCTUnwrap(sandbox["network"] as? [String: Any])
        XCTAssertEqual(network["deniedDomains"] as? [String], ["*"])
        XCTAssertEqual((sandbox["filesystem"] as? [String: Any])?["allowWrite"] as? [String], ["/tmp", "/private/tmp"])
        XCTAssertFalse(launch.arguments.contains("--strict-mcp-config"))
    }
}

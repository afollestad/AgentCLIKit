import XCTest

@testable import AgentCLIKit

final class RuntimeIntegrationIsolationTests: XCTestCase {
    /// Running unisolated would hand the agent the integrations the host asked to withhold.
    func testUnsupportedIsolationFailsBeforeLaunching() async throws {
        let runtime = DefaultAgentRuntime(adapters: [FakeHarnessAdapter(command: shell("printf 'message:launched\\n'"))])
        let config = AgentSpawnConfig(
            harnessId: .claude,
            workingDirectory: FileManager.default.temporaryDirectory,
            integrationIsolation: .shellNetwork
        )

        do {
            try await runtime.spawn(conversationId: "conversation", config: config)
            XCTFail("Expected unsupported integration isolation to fail.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error.code, .unsupportedCapability)
            XCTAssertEqual(error.metadata["capability"], .string("integration isolation"))
        }
        let status = await runtime.status(conversationId: "conversation")
        XCTAssertNil(status)
    }
}

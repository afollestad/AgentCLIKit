import Foundation
import XCTest

@testable import AgentCLIKit

extension CodexProviderAdapterHostToolTests {
    func testRuntimeWorkspaceRootsRequirePositiveCapabilityProbe() async {
        let transport = FakeCodexAppServerTransport(threadIds: ["silently-accepted-thread"])
        let configuration = CodexProviderAdapter.Configuration(
            experimentalAPIEnabled: true,
            requestTimeout: 0.1,
            probeTimeout: 0.1,
            featureSupportChecker: FixedCodexFeatureSupportChecker(
                supportsFastMode: false,
                supportsGoalMode: false,
                supportsRuntimeWorkspaceRoots: false
            ),
            makeTransport: { _ in transport },
            executableResolver: RecordingExecutableResolver(path: nil)
        )
        let adapter = CodexProviderAdapter(configuration: configuration)
        let config = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            additionalWorkspaceRoots: [URL(fileURLWithPath: "/tmp/grant")]
        )

        do {
            _ = try await adapter.makeLaunchConfiguration(spawnConfig: config, resumedSession: nil)
            XCTFail("Expected runtime workspace roots to require a positive capability probe.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error.code, .unsupportedCapability)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let requestMethods = await transport.requestMethods
        XCTAssertEqual(requestMethods, [])
    }
}

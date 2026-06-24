import Foundation
import XCTest

@testable import AgentCLIKit

final class CodexReasoningSummaryConfigTests: XCTestCase {
    func testReasoningSummaryModeRawValuesAreStable() {
        XCTAssertEqual(AgentReasoningSummaryMode.auto.rawValue, "auto")
        XCTAssertEqual(AgentReasoningSummaryMode.concise.rawValue, "concise")
        XCTAssertEqual(AgentReasoningSummaryMode.detailed.rawValue, "detailed")
        XCTAssertEqual(AgentReasoningSummaryMode.none.rawValue, "none")
    }

    func testBootstrapMapsReasoningSummaryModeToThreadConfig() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))

        _ = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                providerId: .codex,
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                effort: "high",
                reasoningSummaryMode: .auto
            ),
            resumedSession: nil
        )

        let requestParams = await transport.requestParams
        let threadStartParams = try XCTUnwrap(requestParams["thread/start"])
        XCTAssertEqual(threadStartParams.objectValue?["config"], .object([
            "model_reasoning_effort": .string("high"),
            "model_reasoning_summary": .string("auto")
        ]))
    }

    func testBootstrapMapsDisabledReasoningSummaryModeToThreadConfig() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))

        _ = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                providerId: .codex,
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                reasoningSummaryMode: AgentReasoningSummaryMode.none
            ),
            resumedSession: nil
        )

        let requestParams = await transport.requestParams
        let threadStartParams = try XCTUnwrap(requestParams["thread/start"])
        XCTAssertEqual(threadStartParams.objectValue?["config"], .object([
            "model_reasoning_summary": .string("none")
        ]))
    }

    private func configuration(
        transport: FakeCodexAppServerTransport,
        featureSupportChecker: any CodexFeatureSupportChecking = FixedCodexFeatureSupportChecker(supportsFastMode: false)
    ) -> CodexProviderAdapter.Configuration {
        CodexProviderAdapter.Configuration(
            requestTimeout: 0.1,
            probeTimeout: 0.1,
            featureSupportChecker: featureSupportChecker,
            makeTransport: { _ in transport },
            executableResolver: RecordingExecutableResolver(path: nil)
        )
    }
}

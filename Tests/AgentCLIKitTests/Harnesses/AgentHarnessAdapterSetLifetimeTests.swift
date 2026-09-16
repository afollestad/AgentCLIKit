import XCTest

@testable import AgentCLIKit

final class AgentHarnessAdapterSetLifetimeTests: XCTestCase {
    func testDefaultSetsDoNotShareCodexSessionApprovals() async throws {
        let first = AgentHarnessAdapterSet.default
        let second = AgentHarnessAdapterSet.default
        let firstCodex = try XCTUnwrap(first.adapters.first { $0.definition.id == .codex } as? CodexHarnessAdapter)
        let secondCodex = try XCTUnwrap(second.adapters.first { $0.definition.id == .codex } as? CodexHarnessAdapter)
        let request = AgentSessionApprovalRequest(
            harnessId: .codex, conversationId: "conversation", sessionId: "session", toolName: "Bash",
            toolInput: .object(["command": .string("git status")])
        )
        let grant = try XCTUnwrap(request.sessionApprovalGrant(for: .exact))
        let recorded = await firstCodex.configuration.sessionApprovalPolicyStore.recordSessionApproval(grant)
        let firstAllows = await firstCodex.configuration.sessionApprovalPolicyStore.allowsSessionApproval(request)
        let secondAllows = await secondCodex.configuration.sessionApprovalPolicyStore.allowsSessionApproval(request)
        XCTAssertTrue(recorded.isEffective)
        XCTAssertTrue(firstAllows)
        XCTAssertFalse(secondAllows, "Separate default runtimes must not share approval state")
        for adapter in first.adapters + second.adapters { await adapter.shutdownHarnessResources() }
    }

    func testShuttingDownDefaultSetDoesNotPoisonLaterOpenCodeBootstrap() async throws {
        let first = AgentHarnessAdapterSet.default
        for adapter in first.adapters { await adapter.shutdownHarnessResources() }
        let second = AgentHarnessAdapterSet.default
        let openCode = try XCTUnwrap(second.adapters.first { $0.definition.id == .opencode })
        // A missing working directory prevents a real process launch even on machines with OpenCode installed.
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            _ = try await openCode.makeLaunchConfiguration(context: AgentHarnessLaunchContext(
                conversationId: "independent-default", processToken: UUID(),
                spawnConfig: AgentSpawnConfig(harnessId: .opencode, workingDirectory: missing), resumedSession: nil
            ))
            XCTFail("The intentionally missing working directory must prevent startup")
        } catch {
            XCTAssertFalse(error is CancellationError, "Another default set's shutdown must not cancel a new client")
        }
        for adapter in second.adapters { await adapter.shutdownHarnessResources() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}

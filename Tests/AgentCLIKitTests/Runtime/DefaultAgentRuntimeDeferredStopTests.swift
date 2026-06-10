import XCTest

@testable import AgentCLIKit

final class DefaultAgentRuntimeDeferredStopTests: XCTestCase {
    func testRuntimeLetsDeferredStopProcessExitOnStdinClose() async throws {
        // `cat` only ends at stdin EOF; a force kill would report a signal exit code instead of zero.
        let runtime = DefaultAgentRuntime(
            adapters: [
                DeferredToolStopProviderAdapter(command: shell("printf 'approval\\ndeferred\\n'; cat > /dev/null"))
            ],
            deferredStopKillGraceNanoseconds: 60_000_000_000
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await Self.waitForDeferredStop(runtime: runtime, conversationId: conversationId)

        XCTAssertEqual(status?.state, .exited)
        XCTAssertEqual(status?.waitingState, .approval)
        XCTAssertFalse(status?.isProcessRunning ?? true)
        let replay = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let events = await Self.collect(replay.events, limit: (status?.lastEventIndex ?? -1) + 1)
        XCTAssertTrue(events.contains { envelope in
            guard case let .lifecycle(lifecycle) = envelope.event else {
                return false
            }
            return lifecycle.state == .exited && lifecycle.exitCode == 0
        })
    }

    func testRuntimeKillsDeferredStopProcessAfterGracePeriod() async throws {
        // `sleep` ignores stdin EOF, so only the grace-period escalation can end this process.
        let runtime = DefaultAgentRuntime(
            adapters: [
                DeferredToolStopProviderAdapter(command: shell("printf 'approval\\ndeferred\\n'; sleep 30"))
            ],
            deferredStopKillGraceNanoseconds: 100_000_000
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await Self.waitForDeferredStop(runtime: runtime, conversationId: conversationId)

        XCTAssertEqual(status?.state, .exited)
        XCTAssertEqual(status?.waitingState, .approval)
        XCTAssertEqual(status?.inputAvailability, .blocked(reason: "Waiting for approval."))
        XCTAssertFalse(status?.isProcessRunning ?? true)
    }

    private static func waitForDeferredStop(
        runtime: DefaultAgentRuntime,
        conversationId: AgentConversationID
    ) async -> AgentRuntimeStatus? {
        for _ in 0..<300 {
            let status = await runtime.status(conversationId: conversationId)
            if status?.state == .exited, status?.isProcessRunning == false {
                return status
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await runtime.status(conversationId: conversationId)
    }
}

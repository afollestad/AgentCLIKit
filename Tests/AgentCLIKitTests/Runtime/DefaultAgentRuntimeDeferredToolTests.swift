import XCTest

@testable import AgentCLIKit

final class DefaultAgentRuntimeDeferredToolTests: XCTestCase {
    func testRuntimePreservesWaitingStateAfterDeferredApprovalProcessExits() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            DeferredToolStopProviderAdapter(command: shell("printf 'approval\\ndeferred\\n'"))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)

        XCTAssertEqual(status?.state, .exited)
        XCTAssertEqual(status?.waitingState, .approval)
        XCTAssertEqual(status?.inputAvailability, .blocked(reason: "Waiting for approval."))
        XCTAssertFalse(status?.isProcessRunning ?? true)
    }

    func testRuntimeStopsProcessAfterDeferredApproval() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            DeferredToolStopProviderAdapter(command: shell("printf 'approval\\ndeferred\\n'; sleep 5"))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await Self.waitForDeferredStop(runtime: runtime, conversationId: conversationId)

        XCTAssertEqual(status?.state, .exited)
        XCTAssertEqual(status?.waitingState, .approval)
        XCTAssertEqual(status?.inputAvailability, .blocked(reason: "Waiting for approval."))
        XCTAssertFalse(status?.isProcessRunning ?? true)
    }

    func testRuntimeIgnoresStdoutAfterDeferredToolStopPerConversation() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            DeferredToolStopProviderAdapter(command: shell("printf 'deferred\\nmessage:trailing\\n'"))
        ])
        let firstConversationId: AgentConversationID = "first"
        let secondConversationId: AgentConversationID = "second"

        try await runtime.spawn(conversationId: firstConversationId, config: spawnConfig())
        let firstStatus = await waitForExit(runtime: runtime, conversationId: firstConversationId)
        let firstReplay = await runtime.subscribe(conversationId: firstConversationId, afterIndex: nil)
        let firstEvents = await Self.collect(firstReplay.events, limit: (firstStatus?.lastEventIndex ?? -1) + 1)

        try await runtime.spawn(conversationId: secondConversationId, config: spawnConfig())
        let secondStatus = await waitForExit(runtime: runtime, conversationId: secondConversationId)
        let secondReplay = await runtime.subscribe(conversationId: secondConversationId, afterIndex: nil)
        let secondEvents = await Self.collect(secondReplay.events, limit: (secondStatus?.lastEventIndex ?? -1) + 1)

        let deferredUsage = AgentUsageEvent(model: nil, inputTokens: nil, outputTokens: nil, stopReason: "tool_deferred")
        let trailingMessage = AgentMessageEvent(role: .assistant, text: "trailing")

        XCTAssertTrue(firstEvents.contains { $0.event == .usage(deferredUsage) })
        XCTAssertFalse(firstEvents.contains { $0.event == .message(trailingMessage) })
        XCTAssertTrue(secondEvents.contains { $0.event == .usage(deferredUsage) })
        XCTAssertFalse(secondEvents.contains { $0.event == .message(trailingMessage) })
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

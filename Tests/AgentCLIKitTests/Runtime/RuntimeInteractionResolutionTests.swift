import XCTest

@testable import AgentCLIKit

final class RuntimeInteractionResolutionTests: XCTestCase {
    func testRuntimeDoesNotReopenResolvedInteractionFromLateProviderFrame() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("""
            printf 'interaction:prompt\\n'
            read resolution
            printf 'interaction:prompt\\n'
            printf "message:$resolution\\n"
            """))
        ])
        let conversationId: AgentConversationID = "conversation"

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let waitingStatus = await waitForWaitingState(.prompt, runtime: runtime, conversationId: conversationId)
        try await runtime.resolveInteraction(
            AgentInteractionResolution(id: "prompt", outcome: .answered, responseText: "yes"),
            conversationId: conversationId
        )
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "yes")) }
        })
        let promptEvents = events.filter {
            $0.event == .interaction(AgentInteractionEvent(id: "prompt", kind: .prompt, prompt: "Continue?"))
        }
        let finalStatus = await waitForExit(runtime: runtime, conversationId: conversationId)

        XCTAssertEqual(waitingStatus?.waitingState, .prompt)
        XCTAssertEqual(promptEvents.count, 1)
        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "yes")) })
        XCTAssertEqual(finalStatus?.waitingState, .idle)
    }

    private func waitForWaitingState(
        _ waitingState: AgentRuntimeWaitingState,
        runtime: DefaultAgentRuntime,
        conversationId: AgentConversationID
    ) async -> AgentRuntimeStatus? {
        for _ in 0..<100 {
            let status = await runtime.status(conversationId: conversationId)
            if status?.waitingState == waitingState {
                return status
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await runtime.status(conversationId: conversationId)
    }
}

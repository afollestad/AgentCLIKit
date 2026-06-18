import XCTest

@testable import AgentCLIKit

final class DefaultAgentRuntimeSubAgentTests: XCTestCase {
    func testSubAgentEventsDeduplicateExactReplayAndAllowDistinctProgress() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell([
                "subagent:started",
                "subagent:started",
                "subagent:progress",
                "subagent:progress",
                "subagent:progress-metadata",
                "subagent:progress2",
                "subagent:terminal",
                "subagent:terminal"
            ].map { "printf '\($0)\\n'" }.joined(separator: "; ")))
        ])
        let conversationId: AgentConversationID = "conversation"
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { envelope in
                envelope.event == .lifecycle(AgentLifecycleEvent(state: .exited, exitCode: 0))
            }
        })
        let subAgents = events.subAgentEvents

        XCTAssertEqual(subAgents.map(\.phase), [.started, .progress, .progress, .progress, .terminal])
        XCTAssertEqual(subAgents.map(\.status), [nil, "running", "running", "writing", "completed"])
        XCTAssertEqual(subAgents.map(\.id), ["agent-1", "agent-1", "agent-1", "agent-1", "agent-1"])
        XCTAssertEqual(subAgents[2].metadata["agents_states"], .object(["agent-1": .object(["message": .string("Writing")])]))
    }

    func testCancelSynthesizesFailedTerminalForOpenSubAgent() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("printf 'subagent:started\\n'; sleep 5"))
        ])
        let conversationId: AgentConversationID = "conversation"
        let startSubscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        _ = await Self.collect(startSubscription.events, until: { envelopes in
            envelopes.subAgentEvents.contains { $0.phase == .started }
        })
        await runtime.cancel(conversationId: conversationId)

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains {
                $0.event == .lifecycle(AgentLifecycleEvent(state: .cancelled, message: "Cancelled by host."))
            }
        })
        let subAgents = events.subAgentEvents

        XCTAssertEqual(subAgents.map(\.phase), [.started, .terminal])
        XCTAssertEqual(subAgents.last?.status, "failed")
        XCTAssertEqual(subAgents.last?.result, "Sub-agent was interrupted by host cancellation.")
        XCTAssertEqual(subAgents.last?.metadata["synthetic"], .bool(true))
        XCTAssertEqual(subAgents.last?.metadata["terminal_reason"], .string("cancelled"))

        await runtime.shutdown()
    }

    func testProcessExitSynthesizesFailedTerminalForOpenSubAgent() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("printf 'subagent:started\\n'"))
        ])
        let conversationId: AgentConversationID = "conversation"
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { envelope in
                envelope.event == .lifecycle(AgentLifecycleEvent(state: .exited, exitCode: 0))
            }
        })
        let subAgents = events.subAgentEvents

        XCTAssertEqual(subAgents.map(\.phase), [.started, .terminal])
        XCTAssertEqual(subAgents.last?.status, "failed")
        XCTAssertEqual(subAgents.last?.result, "Sub-agent did not finish before the provider process ended.")
        XCTAssertEqual(subAgents.last?.metadata["synthetic"], .bool(true))
        XCTAssertEqual(subAgents.last?.metadata["terminal_reason"], .string("exited"))
    }
}

private extension [AgentEventEnvelope] {
    var subAgentEvents: [AgentSubAgentEvent] {
        compactMap { envelope -> AgentSubAgentEvent? in
            guard case let .subAgent(subAgent) = envelope.event else {
                return nil
            }
            return subAgent
        }
    }
}

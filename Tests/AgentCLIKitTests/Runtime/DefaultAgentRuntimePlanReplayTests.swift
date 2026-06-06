import XCTest

@testable import AgentCLIKit

final class DefaultAgentRuntimePlanReplayTests: XCTestCase {
    func testDeferredApprovalResumeSuppressesPlanFileApprovalReplayWithFreshInteractionID() async throws {
        let launches = LaunchSequence([
            shell("printf 'message:Writing a test plan now.\\nplan-approval:write-original:write\\ndeferred\\n'"),
            shell("printf 'message:Writing a test plan now.\\nplan-approval:write-replayed:write\\ndeferred\\nmessage:updated\\n'")
        ])
        let runtime = DefaultAgentRuntime(adapters: [
            PlanFileReplayProviderAdapter(launchSequence: launches)
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let firstStatus = await waitForExit(runtime: runtime, conversationId: conversationId)
        let afterIndex = firstStatus?.lastEventIndex ?? -1

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: afterIndex)
        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let events = await Self.collect(subscription.events, until: {
            $0.contains { envelope in
                envelope.event == .message(AgentMessageEvent(role: .assistant, text: "updated"))
            }
        })

        XCTAssertFalse(events.contains {
            $0.event == .message(AgentMessageEvent(role: .assistant, text: "Writing a test plan now."))
        })
        XCTAssertFalse(events.contains { envelope in
            if case .interaction = envelope.event {
                return true
            }
            return false
        })
        XCTAssertFalse(events.contains { $0.event == .usage(Self.deferredUsage) })
        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "updated")) })
    }

    func testDeferredApprovalResumeKeepsNewPlanFileApprovalWithDifferentInput() async throws {
        let launches = LaunchSequence([
            shell("printf 'plan-approval:write-original:write\\ndeferred\\n'"),
            shell("printf 'plan-approval:edit-new:edit\\nmessage:updated\\n'")
        ])
        let runtime = DefaultAgentRuntime(adapters: [
            PlanFileReplayProviderAdapter(launchSequence: launches)
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let firstStatus = await waitForExit(runtime: runtime, conversationId: conversationId)
        let afterIndex = firstStatus?.lastEventIndex ?? -1

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: afterIndex)
        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let events = await Self.collect(subscription.events, until: {
            $0.contains { envelope in
                envelope.event == .message(AgentMessageEvent(role: .assistant, text: "updated"))
            }
        })

        XCTAssertTrue(events.contains { envelope in
            guard case let .interaction(interaction) = envelope.event else {
                return false
            }
            return interaction.id == "edit-new"
        })
        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "updated")) })
    }

    fileprivate static let deferredUsage = AgentUsageEvent(
        model: nil,
        inputTokens: nil,
        outputTokens: nil,
        stopReason: "tool_deferred"
    )
}

private struct PlanFileReplayProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(id: .claude, displayName: "Fake", executableNames: ["fake"])
    let launchSequence: LaunchSequence

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        await launchSequence.next()
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        if let text = line.removingPrefix("message:") {
            return [.message(AgentMessageEvent(role: .assistant, text: text))]
        }
        if let rawPlanApproval = line.removingPrefix("plan-approval:") {
            return planApprovalEvents(from: rawPlanApproval)
        }
        if line == "deferred" {
            return [.usage(DefaultAgentRuntimePlanReplayTests.deferredUsage)]
        }
        return []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }

    private func planApprovalEvents(from rawPlanApproval: String) -> [AgentEvent] {
        let components = rawPlanApproval.split(separator: ":", maxSplits: 1).map(String.init)
        guard components.count == 2 else {
            return []
        }
        let isWrite = components[1] == "write"
        return [.interaction(AgentInteractionEvent(
            id: AgentInteractionID(rawValue: components[0]),
            kind: .approval,
            prompt: isWrite ? "Write" : "Edit",
            metadata: [
                "session_id": .string("session-1"),
                "tool_name": .string(isWrite ? "Write" : "Edit"),
                "tool_input": .object([
                    "file_path": .string("/Users/afollestad/.claude/plans/test-plan.md"),
                    "content": .string(components[1])
                ])
            ]
        ))]
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else {
            return nil
        }
        return String(dropFirst(prefix.count))
    }
}

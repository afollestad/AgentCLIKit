import XCTest

@testable import AgentCLIKit

final class CodexTaskItemDecoderTests: XCTestCase {
    private let decoder = CodexAppServerNotificationDecoder()

    func testDecodesCollaborationItem() {
        let events = decoder.decode(itemCompleted(item: collaborationItem())).map(\.event)

        XCTAssertEqual(events, [
            .subAgent(expectedCollaborationEvent(phase: .started)),
            .subAgent(expectedCollaborationEvent(phase: .terminal))
        ])
    }

    func testDecodesFailedCollaborationItemWithResult() {
        let events = decoder.decode(itemCompleted(item: collaborationItem(
            id: "collab-failed",
            status: "failed",
            result: "Full-history forked agents inherit the parent agent type."
        ))).map(\.event)

        XCTAssertEqual(events, [
            .subAgent(AgentSubAgentEvent(
                id: "collab-failed",
                phase: .terminal,
                description: "Review the diff",
                prompt: "Review the diff",
                agentType: "codex",
                input: .object([
                    "description": .string("Review the diff"),
                    "prompt": .string("Review the diff"),
                    "subagent_type": .string("codex"),
                    "codex_collab_tool": .string("spawnAgent")
                ]),
                lastToolName: "spawnAgent",
                status: "failed",
                result: "Full-history forked agents inherit the parent agent type.",
                parentSessionId: "thread-1",
                childSessionIds: ["thread-child"],
                metadata: itemMetadata(
                    phase: "completed",
                    itemId: "collab-failed",
                    type: "collabAgentToolCall",
                    status: "failed",
                    values: collaborationMetadata().merging([
                        "result": .string("Full-history forked agents inherit the parent agent type.")
                    ]) { _, new in new }
                )
            ))
        ])
    }

    func testIgnoresCollaborationSpawnAgentStartUntilCompletion() {
        let camelEvents = decoder.decode(itemStarted(item: collaborationItem(tool: "spawnAgent", status: "inProgress"))).map(\.event)

        XCTAssertEqual(camelEvents, [])
    }

    func testIgnoresCollaborationSpawnAgentSnakeCaseStartUntilCompletion() {
        let snakeEvents = decoder.decode(itemStarted(item: collaborationItem(id: "collab-2", tool: "spawn_agent", status: "inProgress")))
            .map(\.event)

        XCTAssertEqual(snakeEvents, [])
    }

    func testSuccessfulCollaborationCompletionEmitsStartAndTerminal() {
        let events = decoder.decode(itemCompleted(item: collaborationItem(id: "collab-2", tool: "spawn_agent"))).map(\.event)

        XCTAssertEqual(events, [
            .subAgent(expectedCollaborationEvent(id: "collab-2", tool: "spawn_agent", phase: .started)),
            .subAgent(expectedCollaborationEvent(id: "collab-2", tool: "spawn_agent", phase: .terminal))
        ])
    }

    func testFailedCollaborationCompletionDoesNotEmitStart() {
        let events = decoder.decode(itemCompleted(item: collaborationItem(
            id: "collab-failed",
            status: "failed",
            result: "Full-history forked agents inherit the parent agent type."
        ))).map(\.event)

        XCTAssertEqual(events.count, 1)
        guard case .subAgent(let subAgent)? = events.first else {
            return XCTFail("Expected failed sub-agent terminal event")
        }
        XCTAssertEqual(subAgent.id, "collab-failed")
        XCTAssertEqual(subAgent.phase, .terminal)
        XCTAssertEqual(subAgent.status, "failed")
    }

    func testChildlessCollaborationCompletionDoesNotEmitStart() {
        let events = decoder.decode(itemCompleted(item: collaborationItem(includeReceiver: false))).map(\.event)

        XCTAssertEqual(events.count, 1)
        guard case .subAgent(let subAgent)? = events.first else {
            return XCTFail("Expected childless sub-agent terminal event")
        }
        XCTAssertEqual(subAgent.phase, .terminal)
        XCTAssertEqual(subAgent.childSessionIds, [])
    }

    func testIgnoresCollaborationWaitAndCloseItems() {
        let waitEvents = decoder.decode(itemStarted(item: collaborationItem(tool: "waitAgent"))).map(\.event)
        let closeEvents = decoder.decode(itemCompleted(item: collaborationItem(tool: "closeAgent"))).map(\.event)

        XCTAssertEqual(waitEvents, [])
        XCTAssertEqual(closeEvents, [])
    }

    func testDecodesContextCompactionItem() {
        let startedEvents = decoder.decode(itemStarted(item: [
            "id": .string("compact-1"),
            "type": .string("contextCompaction"),
            "trigger": .string("auto"),
            "preTokens": .number(120_000)
        ])).map(\.event)
        let completedEvents = decoder.decode(itemCompleted(item: [
            "id": .string("compact-1"),
            "type": .string("contextCompaction"),
            "status": .string("completed"),
            "summary": .string("Retained recent context."),
            "postTokens": .number(30_000),
            "durationMs": .number(750)
        ])).map(\.event)

        XCTAssertEqual(startedEvents, [
            .contextCompaction(AgentContextCompactionEvent(
                id: "codex-context-compaction-turn-1",
                phase: .started,
                trigger: "auto",
                preTokens: 120_000,
                metadata: itemMetadata(phase: "started", itemId: "compact-1", type: "contextCompaction")
            ))
        ])
        XCTAssertEqual(completedEvents, [
            .contextCompaction(AgentContextCompactionEvent(
                id: "codex-context-compaction-turn-1",
                phase: .completed,
                summary: "Retained recent context.",
                postTokens: 30_000,
                durationMs: 750,
                metadata: itemMetadata(phase: "completed", itemId: "compact-1", type: "contextCompaction", status: "completed")
            ))
        ])
    }

    func testDecodesRawResponseCompactionAliases() {
        let triggerEvents = decoder.decode(rawResponseItemCompleted(item: [
            "id": .string("raw-1"),
            "type": .string("compaction_trigger"),
            "trigger": .string("manual")
        ])).map(\.event)
        let completedEvents = decoder.decode(rawResponseItemCompleted(item: [
            "id": .string("raw-2"),
            "type": .string("context_compaction"),
            "encrypted_content": .string("provider-internal")
        ])).map(\.event)

        XCTAssertEqual(triggerEvents, [
            .contextCompaction(AgentContextCompactionEvent(
                id: "codex-context-compaction-turn-1",
                phase: .started,
                trigger: "manual",
                metadata: itemMetadata(method: "rawResponseItem/completed", phase: "completed", itemId: "raw-1", type: "compaction_trigger")
            ))
        ])
        XCTAssertEqual(completedEvents, [
            .contextCompaction(AgentContextCompactionEvent(
                id: "codex-context-compaction-turn-1",
                phase: .completed,
                metadata: itemMetadata(method: "rawResponseItem/completed", phase: "completed", itemId: "raw-2", type: "context_compaction")
            ))
        ])
    }

    private func collaborationItem(
        id: String = "collab-1",
        tool: String = "spawnAgent",
        status: String = "completed",
        result: String? = nil,
        includeReceiver: Bool = true
    ) -> [String: JSONValue] {
        var item: [String: JSONValue] = [
            "id": .string(id),
            "type": .string("collabAgentToolCall"),
            "tool": .string(tool),
            "status": .string(status),
            "senderThreadId": .string("thread-1"),
            "model": .string("model-a"),
            "reasoningEffort": .string("high"),
            "prompt": .string("Review the diff")
        ]
        if includeReceiver {
            item["receiverThreadIds"] = .array([.string("thread-child")])
            item["agentsStates"] = .object([
                "thread-child": .object([
                    "status": .string("completed"),
                    "message": .string("Done")
                ])
            ])
        }
        if let result {
            item["result"] = .string(result)
        }
        return item
    }

    private func collaborationMetadata(statusTool tool: String = "spawnAgent") -> [String: JSONValue] {
        [
            "codex_collab_tool": .string(tool),
            "sender_thread_id": .string("thread-1"),
            "receiver_thread_ids": .array([.string("thread-child")]),
            "agents_states": .object([
                "thread-child": .object([
                    "status": .string("completed"),
                    "message": .string("Done")
                ])
            ]),
            "model": .string("model-a"),
            "reasoning_effort": .string("high"),
            "prompt": .string("Review the diff")
        ]
    }

    private func expectedCollaborationEvent(
        id: String = "collab-1",
        tool: String = "spawnAgent",
        phase: AgentSubAgentPhase
    ) -> AgentSubAgentEvent {
        AgentSubAgentEvent(
            id: id,
            phase: phase,
            description: "Review the diff",
            prompt: "Review the diff",
            agentType: "codex",
            input: .object([
                "description": .string("Review the diff"),
                "prompt": .string("Review the diff"),
                "subagent_type": .string("codex"),
                "codex_collab_tool": .string(tool)
            ]),
            lastToolName: tool,
            status: "completed",
            parentSessionId: "thread-1",
            childSessionIds: ["thread-child"],
            metadata: itemMetadata(
                phase: "completed",
                itemId: id,
                type: "collabAgentToolCall",
                status: "completed",
                values: collaborationMetadata(statusTool: tool)
            )
        )
    }

    private func itemStarted(item: [String: JSONValue]) -> CodexAppServerNotification {
        notification(method: "item/started", params: [
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "startedAtMs": .number(1),
            "item": .object(item)
        ])
    }

    private func itemCompleted(item: [String: JSONValue]) -> CodexAppServerNotification {
        notification(method: "item/completed", params: [
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "completedAtMs": .number(2),
            "item": .object(item)
        ])
    }

    private func rawResponseItemCompleted(item: [String: JSONValue]) -> CodexAppServerNotification {
        notification(method: "rawResponseItem/completed", params: [
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "completedAtMs": .number(2),
            "item": .object(item)
        ])
    }

    private func notification(method: String, params: [String: JSONValue]) -> CodexAppServerNotification {
        CodexAppServerNotification(method: method, params: .object(params))
    }

    private func itemMetadata(
        method: String? = nil,
        phase: String,
        itemId: String,
        type: String,
        status: String? = nil,
        values: [String: JSONValue] = [:]
    ) -> [String: JSONValue] {
        var metadata: [String: JSONValue] = [
            "codex_method": .string(method ?? "item/\(phase)"),
            "codex_thread_id": .string("thread-1"),
            "codex_turn_id": .string("turn-1"),
            "codex_item_id": .string(itemId),
            "codex_item_type": .string(type),
            "codex_item_phase": .string(phase),
            "\(phase)_at_ms": .number(phase == "started" ? 1 : 2)
        ]
        if let status {
            metadata["codex_status"] = .string(status)
        }
        metadata.merge(values) { _, new in new }
        return metadata
    }
}

import XCTest

@testable import AgentCLIKit

final class CodexTaskItemDecoderTests: XCTestCase {
    private let decoder = CodexAppServerNotificationDecoder()

    func testDecodesCollaborationItem() {
        let events = decoder.decode(itemCompleted(item: collaborationItem())).map(\.event)

        XCTAssertEqual(events, [
            .subAgent(AgentSubAgentEvent(
                id: "collab-1",
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
                status: "completed",
                parentSessionId: "thread-1",
                childSessionIds: ["thread-child"],
                metadata: itemMetadata(
                    phase: "completed",
                    itemId: "collab-1",
                    type: "collabAgentToolCall",
                    status: "completed",
                    values: collaborationMetadata()
                )
            ))
        ])
    }

    func testDecodesCollaborationSpawnAgentStart() {
        let camelEvents = decoder.decode(itemStarted(item: collaborationItem(tool: "spawnAgent", status: "inProgress"))).map(\.event)

        XCTAssertEqual(camelEvents.first, .subAgent(AgentSubAgentEvent(
            id: "collab-1",
            phase: .started,
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
            status: "inProgress",
            parentSessionId: "thread-1",
            childSessionIds: ["thread-child"],
            metadata: itemMetadata(
                phase: "started",
                itemId: "collab-1",
                type: "collabAgentToolCall",
                status: "inProgress",
                values: collaborationMetadata(statusTool: "spawnAgent")
            )
        )))
    }

    func testDecodesCollaborationSpawnAgentSnakeCaseStart() {
        let snakeEvents = decoder.decode(itemStarted(item: collaborationItem(id: "collab-2", tool: "spawn_agent", status: "inProgress")))
            .map(\.event)

        XCTAssertEqual(snakeEvents.first, .subAgent(AgentSubAgentEvent(
            id: "collab-2",
            phase: .started,
            description: "Review the diff",
            prompt: "Review the diff",
            agentType: "codex",
            input: .object([
                "description": .string("Review the diff"),
                "prompt": .string("Review the diff"),
                "subagent_type": .string("codex"),
                "codex_collab_tool": .string("spawn_agent")
            ]),
            lastToolName: "spawn_agent",
            status: "inProgress",
            parentSessionId: "thread-1",
            childSessionIds: ["thread-child"],
            metadata: itemMetadata(
                phase: "started",
                itemId: "collab-2",
                type: "collabAgentToolCall",
                status: "inProgress",
                values: collaborationMetadata(statusTool: "spawn_agent")
            )
        )))
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
        status: String = "completed"
    ) -> [String: JSONValue] {
        [
            "id": .string(id),
            "type": .string("collabAgentToolCall"),
            "tool": .string(tool),
            "status": .string(status),
            "senderThreadId": .string("thread-1"),
            "receiverThreadIds": .array([.string("thread-child")]),
            "agentsStates": .object([
                "thread-child": .object([
                    "status": .string("completed"),
                    "message": .string("Done")
                ])
            ]),
            "model": .string("model-a"),
            "reasoningEffort": .string("high"),
            "prompt": .string("Review the diff")
        ]
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

import XCTest

@testable import AgentCLIKit

final class CodexTaskItemDecoderTests: XCTestCase {
    private let decoder = CodexAppServerNotificationDecoder()

    func testDecodesCollaborationItem() {
        let events = decoder.decode(itemCompleted(item: collaborationItem())).map(\.event)

        XCTAssertEqual(events, [
            .task(AgentTaskEvent(
                id: "collab-1",
                phase: .completed,
                description: "Review the diff",
                taskType: "collabAgentToolCall",
                lastToolName: "spawnAgent",
                status: "completed",
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

    func testDecodesContextCompactionItem() {
        let events = decoder.decode(itemStarted(item: [
            "id": .string("compact-1"),
            "type": .string("contextCompaction")
        ])).map(\.event)

        XCTAssertEqual(events, [
            .task(AgentTaskEvent(
                id: "compact-1",
                phase: .started,
                description: "Compacting context",
                taskType: "contextCompaction",
                metadata: itemMetadata(phase: "started", itemId: "compact-1", type: "contextCompaction")
            ))
        ])
    }

    private func collaborationItem() -> [String: JSONValue] {
        [
            "id": .string("collab-1"),
            "type": .string("collabAgentToolCall"),
            "tool": .string("spawnAgent"),
            "status": .string("completed"),
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

    private func collaborationMetadata() -> [String: JSONValue] {
        [
            "codex_collab_tool": .string("spawnAgent"),
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

    private func notification(method: String, params: [String: JSONValue]) -> CodexAppServerNotification {
        CodexAppServerNotification(method: method, params: .object(params))
    }

    private func itemMetadata(
        phase: String,
        itemId: String,
        type: String,
        status: String? = nil,
        values: [String: JSONValue] = [:]
    ) -> [String: JSONValue] {
        var metadata: [String: JSONValue] = [
            "codex_method": .string("item/\(phase)"),
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

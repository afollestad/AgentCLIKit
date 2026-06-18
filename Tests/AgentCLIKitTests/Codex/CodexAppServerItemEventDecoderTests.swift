import XCTest

@testable import AgentCLIKit

// swiftlint:disable:next type_body_length
final class CodexAppServerItemEventDecoderTests: XCTestCase {
    private let decoder = CodexAppServerNotificationDecoder()

    func testDecodesAgentMessageAndReasoningDeltas() {
        let messageEvents = decoder.decode(notification(
            method: "item/agentMessage/delta",
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("message-1"),
                "delta": .string("Hel")
            ]
        )).map(\.event)
        let reasoningEvents = decoder.decode(notification(
            method: "item/reasoning/textDelta",
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("reasoning-1"),
                "contentIndex": .number(0),
                "delta": .string("Thinking")
            ]
        )).map(\.event)

        XCTAssertEqual(messageEvents, [
            .messageDelta(AgentMessageDeltaEvent(
                role: .assistant,
                text: "Hel",
                metadata: itemMetadata(method: "item/agentMessage/delta", itemId: "message-1")
            ))
        ])
        XCTAssertEqual(reasoningEvents, [
            .reasoning(AgentReasoningEvent(
                text: "Thinking",
                metadata: itemMetadata(
                    method: "item/reasoning/textDelta",
                    itemId: "reasoning-1",
                    values: [
                        "codex_reasoning_kind": .string("content"),
                        "codex_reasoning_index": .number(0)
                    ]
                )
            ))
        ])
    }

    // swiftlint:disable:next function_body_length
    func testDecodesCompletedMessagesAndReasoningItems() {
        let userEvents = decoder.decode(itemCompleted(item: [
            "id": .string("user-1"),
            "type": .string("userMessage"),
            "clientId": .string("client-1"),
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("Run tests"),
                    "unknown": .string("ignored")
                ]),
                .object([
                    "type": .string("mention"),
                    "name": .string("README.md"),
                    "path": .string("/tmp/project/README.md")
                ])
            ])
        ])).map(\.event)
        let assistantEvents = decoder.decode(itemCompleted(item: [
            "id": .string("message-1"),
            "type": .string("agentMessage"),
            "text": .string("Done"),
            "phase": .string("final"),
            "extra": .object(["field": .string("ignored")])
        ])).map(\.event)
        let reasoningEvents = decoder.decode(itemCompleted(item: [
            "id": .string("reasoning-1"),
            "type": .string("reasoning"),
            "content": .array([.string("Private notes")]),
            "summary": .array([.string("Summary")])
        ])).map(\.event)

        XCTAssertEqual(userEvents, [
            .message(AgentMessageEvent(
                role: .user,
                text: "Run tests\n@README.md",
                metadata: completedItemMetadata(
                    itemId: "user-1",
                    type: "userMessage",
                    values: ["codex_client_user_message_id": .string("client-1")]
                )
            ))
        ])
        XCTAssertEqual(assistantEvents, [
            .message(AgentMessageEvent(
                role: .assistant,
                text: "Done",
                metadata: completedItemMetadata(itemId: "message-1", type: "agentMessage")
            ))
        ])
        XCTAssertEqual(reasoningEvents, [
            .reasoning(AgentReasoningEvent(
                text: "Private notes",
                metadata: completedItemMetadata(
                    itemId: "reasoning-1",
                    type: "reasoning",
                    values: ["codex_reasoning_kind": .string("content")]
                )
            )),
            .reasoning(AgentReasoningEvent(
                text: "Summary",
                metadata: completedItemMetadata(
                    itemId: "reasoning-1",
                    type: "reasoning",
                    values: ["codex_reasoning_kind": .string("summary")]
                )
            ))
        ])
    }

    // swiftlint:disable:next function_body_length
    func testDecodesCommandExecutionItemsAndOutputDelta() {
        let startedEvents = decoder.decode(itemStarted(item: [
            "id": .string("cmd-1"),
            "type": .string("commandExecution"),
            "command": .string("swift test"),
            "commandActions": .array([.object([
                "type": .string("unknown"),
                "command": .string("swift test")
            ])]),
            "cwd": .string("/tmp/project"),
            "source": .string("agent"),
            "status": .string("inProgress")
        ])).map(\.event)
        let outputEvents = decoder.decode(notification(
            method: "item/commandExecution/outputDelta",
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("cmd-1"),
                "delta": .string("Compiling")
            ]
        )).map(\.event)
        let completedEvents = decoder.decode(itemCompleted(item: [
            "id": .string("cmd-1"),
            "type": .string("commandExecution"),
            "command": .string("swift test"),
            "commandActions": .array([]),
            "cwd": .string("/tmp/project"),
            "status": .string("completed"),
            "exitCode": .number(0),
            "durationMs": .number(42),
            "aggregatedOutput": .string("Tests passed")
        ])).map(\.event)

        XCTAssertEqual(startedEvents, [
            .toolCall(AgentToolCallEvent(
                id: "cmd-1",
                name: "CommandExecution",
                input: .object([
                    "command": .string("swift test"),
                    "commandActions": .array([.object([
                        "type": .string("unknown"),
                        "command": .string("swift test")
                    ])]),
                    "cwd": .string("/tmp/project"),
                    "source": .string("agent")
                ]),
                metadata: startedItemMetadata(itemId: "cmd-1", type: "commandExecution", status: "inProgress")
            ))
        ])
        XCTAssertEqual(outputEvents, [.rawOutput(AgentRawOutputEvent(text: "Compiling", isComplete: false))])
        XCTAssertEqual(completedEvents, [
            .toolResult(AgentToolResultEvent(
                id: "cmd-1",
                isError: false,
                content: "Tests passed",
                metadata: completedItemMetadata(
                    itemId: "cmd-1",
                    type: "commandExecution",
                    status: "completed",
                    values: [
                        "tool_name": .string("CommandExecution"),
                        "exit_code": .number(0),
                        "duration_ms": .number(42)
                    ]
                )
            ))
        ])
    }

    // swiftlint:disable:next function_body_length
    func testDecodesFileChangeDiffNotificationsAndItems() {
        let changes: JSONValue = .array([.object([
            "path": .string("Sources/App.swift"),
            "kind": .object(["type": .string("update")]),
            "diff": .string("@@ -1 +1 @@\n-old\n+new")
        ])])
        let patchUpdatedEvents = decoder.decode(notification(
            method: "fileChange/patch/updated",
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("patch-1"),
                "changes": changes
            ]
        )).map(\.event)
        let generatedAliasEvents = decoder.decode(notification(
            method: "item/fileChange/patchUpdated",
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("patch-1"),
                "changes": changes
            ]
        )).map(\.event)
        let turnDiffEvents = decoder.decode(notification(
            method: "turn/diff/updated",
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "diff": .string("@@ -1 +1 @@\n-old\n+new")
            ]
        )).map(\.event)
        let completedEvents = decoder.decode(itemCompleted(item: [
            "id": .string("patch-1"),
            "type": .string("fileChange"),
            "status": .string("completed"),
            "changes": changes
        ])).map(\.event)

        let patchText = "Sources/App.swift\nkind: update\n@@ -1 +1 @@\n-old\n+new"
        XCTAssertEqual(patchUpdatedEvents, [
            .toolResult(AgentToolResultEvent(
                id: "patch-1",
                isError: false,
                content: patchText,
                metadata: itemMetadata(
                    method: "fileChange/patch/updated",
                    itemId: "patch-1",
                    values: [
                        "codex_item_type": .string("fileChange"),
                        "codex_item_phase": .string("patchUpdated"),
                        "codex_diff_scope": .string("item")
                    ]
                )
            ))
        ])
        XCTAssertEqual(generatedAliasEvents.count, 1)
        XCTAssertEqual(turnDiffEvents, [
            .toolResult(AgentToolResultEvent(
                id: "codex-turn-diff-turn-1",
                isError: false,
                content: "@@ -1 +1 @@\n-old\n+new",
                metadata: itemMetadata(
                    method: "turn/diff/updated",
                    itemId: nil,
                    values: [
                        "codex_item_type": .string("turnDiff"),
                        "codex_diff_scope": .string("turn")
                    ]
                )
            ))
        ])
        XCTAssertEqual(completedEvents, [
            .toolResult(AgentToolResultEvent(
                id: "patch-1",
                isError: false,
                content: patchText,
                metadata: completedItemMetadata(
                    itemId: "patch-1",
                    type: "fileChange",
                    status: "completed",
                    values: ["tool_name": .string("FileChange")]
                )
            ))
        ])
    }

    // swiftlint:disable:next function_body_length
    func testDecodesMCPToolCallItemsAndProgress() {
        let startedEvents = decoder.decode(itemStarted(item: [
            "id": .string("mcp-1"),
            "type": .string("mcpToolCall"),
            "server": .string("github"),
            "tool": .string("search"),
            "arguments": .object(["query": .string("Codex")]),
            "status": .string("inProgress"),
            "pluginId": .string("plugin-1")
        ])).map(\.event)
        let progressEvents = decoder.decode(notification(
            method: "item/mcpToolCall/progress",
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("mcp-1"),
                "message": .string("Searching")
            ]
        )).map(\.event)
        let completedEvents = decoder.decode(itemCompleted(item: [
            "id": .string("mcp-1"),
            "type": .string("mcpToolCall"),
            "server": .string("github"),
            "tool": .string("search"),
            "arguments": .object(["query": .string("Codex")]),
            "status": .string("completed"),
            "durationMs": .number(10),
            "result": .object([
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string("Found it")
                ])])
            ])
        ])).map(\.event)

        XCTAssertEqual(startedEvents, [
            .toolCall(AgentToolCallEvent(
                id: "mcp-1",
                name: "search",
                input: .object(["query": .string("Codex")]),
                metadata: startedItemMetadata(
                    itemId: "mcp-1",
                    type: "mcpToolCall",
                    status: "inProgress",
                    values: [
                        "mcp_server": .string("github"),
                        "mcp_plugin_id": .string("plugin-1")
                    ]
                )
            ))
        ])
        XCTAssertEqual(progressEvents, [
            .toolResult(AgentToolResultEvent(
                id: "mcp-1",
                isError: false,
                content: "Searching",
                metadata: itemMetadata(
                    method: "item/mcpToolCall/progress",
                    itemId: "mcp-1",
                    values: [
                        "codex_item_type": .string("mcpToolCall"),
                        "codex_item_phase": .string("progress")
                    ]
                )
            ))
        ])
        XCTAssertEqual(completedEvents, [
            .toolResult(AgentToolResultEvent(
                id: "mcp-1",
                isError: false,
                content: "Found it",
                metadata: completedItemMetadata(
                    itemId: "mcp-1",
                    type: "mcpToolCall",
                    status: "completed",
                    values: [
                        "tool_name": .string("search"),
                        "mcp_server": .string("github"),
                        "duration_ms": .number(10)
                    ]
                )
            ))
        ])
    }

    func testIgnoresOutOfScopeAndUnknownItemTypes() {
        let imageEvents = decoder.decode(itemCompleted(item: [
            "id": .string("image-1"),
            "type": .string("imageGeneration"),
            "status": .string("completed"),
            "result": .string("generated"),
            "unexpected": .object(["field": .string("ok")])
        ])).map(\.event)
        let unknownEvents = decoder.decode(itemCompleted(item: [
            "id": .string("unknown-1"),
            "type": .string("futureItem"),
            "future": .bool(true)
        ])).map(\.event)

        XCTAssertEqual(imageEvents, [])
        XCTAssertEqual(unknownEvents, [])
    }

    private func notification(method: String, params: [String: JSONValue]) -> CodexAppServerNotification {
        CodexAppServerNotification(method: method, params: .object(params))
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

    private func snakeCaseItemCompleted(item: [String: JSONValue]) -> CodexAppServerNotification {
        notification(method: "item_completed", params: [
            "thread_id": .string("thread-1"),
            "turn_id": .string("turn-1"),
            "completed_at_ms": .number(2),
            "item": .object(item)
        ])
    }

    private func startedItemMetadata(
        itemId: String,
        type: String,
        status: String? = nil,
        values: [String: JSONValue] = [:]
    ) -> [String: JSONValue] {
        itemMetadata(
            method: "item/started",
            itemId: itemId,
            values: [
                "codex_item_type": .string(type),
                "codex_item_phase": .string("started"),
                "started_at_ms": .number(1)
            ].merging(status.map { ["codex_status": .string($0)] } ?? [:]) { _, new in new }
                .merging(values) { _, new in new }
        )
    }

    private func completedItemMetadata(
        itemId: String,
        type: String,
        status: String? = nil,
        method: String = "item/completed",
        values: [String: JSONValue] = [:]
    ) -> [String: JSONValue] {
        itemMetadata(
            method: method,
            itemId: itemId,
            values: [
                "codex_item_type": .string(type),
                "codex_item_phase": .string("completed"),
                "completed_at_ms": .number(2)
            ].merging(status.map { ["codex_status": .string($0)] } ?? [:]) { _, new in new }
                .merging(values) { _, new in new }
        )
    }

    private func itemMetadata(
        method: String,
        itemId: String? = nil,
        values: [String: JSONValue] = [:]
    ) -> [String: JSONValue] {
        var metadata: [String: JSONValue] = [
            "codex_method": .string(method),
            "codex_thread_id": .string("thread-1"),
            "codex_turn_id": .string("turn-1")
        ]
        if let itemId {
            metadata["codex_item_id"] = .string(itemId)
        }
        metadata.merge(values) { _, new in new }
        return metadata
    }
}

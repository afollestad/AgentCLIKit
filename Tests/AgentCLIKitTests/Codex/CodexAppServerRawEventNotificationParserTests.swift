import XCTest

@testable import AgentCLIKit

final class CodexAppServerRawEventNotificationParserTests: XCTestCase {
    private var parser = CodexAppServerRawEventNotificationParser()
    private let decoder = CodexAppServerNotificationDecoder()

    func testParsesRawCompletedPlanEventAsAssistantMessage() throws {
        let notification = try XCTUnwrap(parser.notification(from: rawCompletedPlanEvent()))

        XCTAssertEqual(notification.method, "item_completed")
        XCTAssertEqual(notification.params, .object([
            "thread_id": .string("thread-1"),
            "turn_id": .string("turn-1"),
            "completed_at_ms": .number(1_781_658_463_687),
            "item": .object([
                "id": .string("turn-1-plan"),
                "type": .string("Plan"),
                "text": .string(Self.planMarkdown)
            ])
        ]))

        XCTAssertEqual(decoder.decode(notification).map(\.event), [
            .message(AgentMessageEvent(
                role: .assistant,
                text: Self.planMarkdown,
                metadata: [
                    AgentPlanProposalMetadata.isProposal: .bool(true),
                    AgentPlanProposalMetadata.proposalId: .string("turn-1-plan"),
                    AgentPlanProposalMetadata.planMarkdown: .string(Self.planMarkdown),
                    "codex_method": .string("item_completed"),
                    "codex_thread_id": .string("thread-1"),
                    "codex_turn_id": .string("turn-1"),
                    "codex_item_id": .string("turn-1-plan"),
                    "codex_item_type": .string("Plan"),
                    "codex_item_phase": .string("completed"),
                    "completed_at_ms": .number(1_781_658_463_687)
                ]
            ))
        ])
    }

    func testIgnoresRawResponseItemWithoutThreadContext() {
        XCTAssertNil(parser.notification(from: [
            "type": .string("response_item"),
            "payload": .object([
                "type": .string("message"),
                "role": .string("assistant"),
                "content": .array([
                    .object([
                        "type": .string("output_text"),
                        "text": .string("<proposed_plan>\n# Plan\n</proposed_plan>")
                    ])
                ])
            ])
        ]))
    }

    func testParsesRejectedSpawnAgentOutputAsFailedSubAgentTerminal() throws {
        XCTAssertNil(parser.notification(from: rawSpawnAgentFunctionCall()))

        let notification = try XCTUnwrap(parser.notification(from: rawSpawnAgentFailureOutput()))

        XCTAssertFailedSpawnNotification(notification)

        XCTAssertEqual(decoder.decode(notification).map(\.event), [expectedFailedSpawnEvent()])
    }

    func testParsesRejectedSpawnAgentOutputWhenOutputArrivesBeforeCall() throws {
        XCTAssertNil(parser.notification(from: rawSpawnAgentFailureOutput()))

        let notification = try XCTUnwrap(parser.notification(from: rawSpawnAgentFunctionCall()))

        XCTAssertFailedSpawnNotification(notification)
        XCTAssertEqual(decoder.decode(notification).map(\.event), [expectedFailedSpawnEvent()])
    }

    func testDoesNotBufferUnmatchedGenericFunctionOutputAsSpawnFailure() {
        XCTAssertNil(parser.notification(from: [
            "type": .string("response_item"),
            "payload": .object([
                "type": .string("function_call_output"),
                "call_id": .string("call-1"),
                "output": .string("normal command output")
            ])
        ]))

        XCTAssertNil(parser.notification(from: rawSpawnAgentFunctionCall()))
    }

    func testParsesRawToolRejectedSpawnAgentOutputAsFailedSubAgentTerminal() throws {
        let notification = try XCTUnwrap(parser.notification(from: rawSpawnAgentToolFailureOutput()))

        XCTAssertFailedSpawnNotification(notification, toolName: "spawn_agent")
        XCTAssertEqual(decoder.decode(notification).map(\.event), [expectedFailedSpawnEvent()])
    }

    func testIgnoresSuccessfulRawSpawnAgentOutput() {
        XCTAssertNil(parser.notification(from: rawSpawnAgentFunctionCall()))
        XCTAssertNil(parser.notification(from: [
            "type": .string("response_item"),
            "payload": .object([
                "type": .string("function_call_output"),
                "call_id": .string("call-1"),
                "output": .string(#"{"agent_id":"agent-1","nickname":"Ada"}"#)
            ])
        ]))
    }

    func testIgnoresSuccessfulRawToolSpawnAgentOutput() {
        XCTAssertNil(parser.notification(from: [
            "type": .string("tool"),
            "payload": .object([
                "tool_name": .string("spawn_agent"),
                "call_id": .string("call-1"),
                "state": .string("output-available"),
                "input": .object(["message": .string("Review the diff")]),
                "output": .array([
                    .object(["type": .string("text"), "text": .string(#"{"agent_id":"agent-1","nickname":"Ada"}"#)])
                ]),
                "metadata": .object(["turn_id": .string("turn-1")])
            ])
        ]))
    }

    func testIgnoresUnsupportedRawEventMessage() {
        XCTAssertNil(parser.notification(from: [
            "type": .string("event_msg"),
            "payload": .object([
                "type": .string("token_count"),
                "info": .object(["total_token_usage": .number(42)])
            ])
        ]))
    }

    func testIgnoresNonPlanCompletedItem() {
        XCTAssertNil(parser.notification(from: [
            "type": .string("event_msg"),
            "payload": .object([
                "type": .string("item_completed"),
                "thread_id": .string("thread-1"),
                "turn_id": .string("turn-1"),
                "item": .object([
                    "id": .string("message-1"),
                    "type": .string("agentMessage"),
                    "text": .string("Done")
                ])
            ])
        ]))
    }

    private func rawCompletedPlanEvent() -> [String: JSONValue] {
        [
            "type": .string("event_msg"),
            "payload": .object([
                "type": .string("item_completed"),
                "thread_id": .string("thread-1"),
                "turn_id": .string("turn-1"),
                "completed_at_ms": .number(1_781_658_463_687),
                "item": .object([
                    "id": .string("turn-1-plan"),
                    "type": .string("Plan"),
                    "text": .string(Self.planMarkdown)
                ])
            ])
        ]
    }

    private func rawSpawnAgentFunctionCall() -> [String: JSONValue] {
        [
            "type": .string("response_item"),
            "payload": .object([
                "type": .string("function_call"),
                "name": .string("spawn_agent"),
                "namespace": .string("multi_agent_v1"),
                "arguments": .string(#"{"fork_context":true,"message":"Review the diff"}"#),
                "call_id": .string("call-1"),
                "metadata": .object(["turn_id": .string("turn-1")])
            ])
        ]
    }

    private func rawSpawnAgentFailureOutput() -> [String: JSONValue] {
        [
            "type": .string("response_item"),
            "payload": .object([
                "type": .string("function_call_output"),
                "call_id": .string("call-1"),
                "output": .string(Self.spawnFailureOutput)
            ])
        ]
    }

    private func rawSpawnAgentToolFailureOutput() -> [String: JSONValue] {
        [
            "type": .string("tool"),
            "payload": .object([
                "tool_name": .string("spawn_agent"),
                "call_id": .string("call-1"),
                "state": .string("output-available"),
                "input": .object([
                    "agent_type": .string("explorer"),
                    "fork_context": .bool(true),
                    "message": .string("Review the diff")
                ]),
                "output": .array([
                    .object(["type": .string("text"), "text": .string(Self.spawnFailureOutput)])
                ]),
                "metadata": .object(["turn_id": .string("turn-1")])
            ])
        ]
    }

    private func XCTAssertFailedSpawnNotification(
        _ notification: CodexAppServerNotification,
        toolName: String = "spawn_agent",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(notification.method, "rawResponseItem/completed", file: file, line: line)
        XCTAssertEqual(notification.params, .object([
            "thread_id": .string("unknown"),
            "turn_id": .string("turn-1"),
            "item": .object([
                "id": .string("call-1"),
                "type": .string("collabAgentToolCall"),
                "tool": .string(toolName),
                "status": .string("failed"),
                "prompt": .string("Review the diff"),
                "result": .string(Self.spawnFailureOutput)
            ])
        ]), file: file, line: line)
    }

    private func expectedFailedSpawnEvent() -> AgentEvent {
        .subAgent(AgentSubAgentEvent(
            id: "call-1",
            phase: .terminal,
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
            status: "failed",
            result: Self.spawnFailureOutput,
            metadata: [
                "codex_method": .string("rawResponseItem/completed"),
                "codex_thread_id": .string("unknown"),
                "codex_turn_id": .string("turn-1"),
                "codex_item_id": .string("call-1"),
                "codex_item_type": .string("collabAgentToolCall"),
                "codex_item_phase": .string("completed"),
                "codex_status": .string("failed"),
                "codex_collab_tool": .string("spawn_agent"),
                "prompt": .string("Review the diff"),
                "result": .string(Self.spawnFailureOutput)
            ]
        ))
    }

    private static let planMarkdown = "# Plan\n\n- Show this plan in the transcript."
    private static let spawnFailureOutput =
        "Full-history forked agents inherit the parent agent type, model, and reasoning effort; " +
        "omit agent_type, model, and reasoning_effort, or spawn without a full-history fork."
}

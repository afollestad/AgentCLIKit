import XCTest

@testable import AgentCLIKit

final class CodexAppServerRawEventNotificationParserTests: XCTestCase {
    private let parser = CodexAppServerRawEventNotificationParser()
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

    private static let planMarkdown = "# Plan\n\n- Show this plan in the transcript."
}

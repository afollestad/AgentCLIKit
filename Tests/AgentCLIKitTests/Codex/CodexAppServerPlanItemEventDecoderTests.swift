import XCTest

@testable import AgentCLIKit

final class CodexAppServerPlanItemEventDecoderTests: XCTestCase {
    private let decoder = CodexAppServerNotificationDecoder()

    func testDecodesCompletedPlanItemAsAssistantMessage() {
        let events = decoder.decode(itemCompleted(method: "item/completed", params: [
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "completedAtMs": .number(2),
            "item": planItem
        ])).map(\.event)

        XCTAssertEqual(events, [
            .message(AgentMessageEvent(
                role: .assistant,
                text: Self.planMarkdown,
                metadata: expectedMetadata(method: "item/completed")
            ))
        ])
    }

    func testDecodesSnakeCaseCompletedPlanItemAsAssistantMessage() {
        let events = decoder.decode(itemCompleted(method: "item_completed", params: [
            "thread_id": .string("thread-1"),
            "turn_id": .string("turn-1"),
            "completed_at_ms": .number(2),
            "item": planItem
        ])).map(\.event)

        XCTAssertEqual(events, [
            .message(AgentMessageEvent(
                role: .assistant,
                text: Self.planMarkdown,
                metadata: expectedMetadata(method: "item_completed")
            ))
        ])
    }

    private var planItem: JSONValue {
        .object([
            "id": .string("plan-1"),
            "type": .string("Plan"),
            "text": .string(Self.planMarkdown)
        ])
    }

    private func itemCompleted(method: String, params: [String: JSONValue]) -> CodexAppServerNotification {
        CodexAppServerNotification(method: method, params: .object(params))
    }

    private func expectedMetadata(method: String) -> [String: JSONValue] {
        [
            AgentPlanProposalMetadata.isProposal: .bool(true),
            AgentPlanProposalMetadata.proposalId: .string("plan-1"),
            AgentPlanProposalMetadata.planMarkdown: .string(Self.planMarkdown),
            "codex_method": .string(method),
            "codex_thread_id": .string("thread-1"),
            "codex_turn_id": .string("turn-1"),
            "codex_item_id": .string("plan-1"),
            "codex_item_type": .string("Plan"),
            "codex_item_phase": .string("completed"),
            "completed_at_ms": .number(2)
        ]
    }

    private static let planMarkdown = "# Plan\n\n- Implement after approval."
}

import XCTest

@testable import AgentCLIKit

final class CodexReasoningItemDecoderTests: XCTestCase {
    private let decoder = CodexAppServerNotificationDecoder()

    func testDecodesSummaryTextDelta() {
        let events = decoder.decode(notification(
            method: "item/reasoning/summaryTextDelta",
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("reasoning-1"),
                "summaryIndex": .number(0),
                "delta": .string("Summary")
            ]
        )).map(\.event)

        XCTAssertEqual(events, [
            .reasoning(AgentReasoningEvent(
                text: "Summary",
                metadata: itemMetadata(
                    method: "item/reasoning/summaryTextDelta",
                    itemId: "reasoning-1",
                    values: [
                        "codex_reasoning_kind": .string("summary"),
                        "codex_reasoning_index": .number(0)
                    ]
                )
            ))
        ])
    }

    func testSummaryPartAddedEmitsNoVisibleEvent() {
        let events = decoder.decode(notification(
            method: "item/reasoning/summaryPartAdded",
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("reasoning-1"),
                "summaryIndex": .number(0),
                "text": .string("")
            ]
        )).map(\.event)

        XCTAssertEqual(events, [])
    }

    private func notification(method: String, params: [String: JSONValue]) -> CodexAppServerNotification {
        CodexAppServerNotification(method: method, params: .object(params))
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

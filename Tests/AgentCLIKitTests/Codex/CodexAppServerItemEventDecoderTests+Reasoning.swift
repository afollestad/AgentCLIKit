import XCTest

@testable import AgentCLIKit

final class CodexReasoningItemDecoderTests: XCTestCase {
    private var decoder = CodexAppServerNotificationDecoder()

    func testDecodesSummaryTextDeltaWithoutLeadingBreak() {
        let events = decoder.decode(summaryDelta(index: 0, delta: "Summary")).map(\.event)

        XCTAssertEqual(events, [reasoning(text: "Summary", kind: "summary", index: 0)])
    }

    func testNewSummaryPartOpensSectionWithParagraphBreak() {
        _ = decoder.decode(summaryDelta(index: 0, delta: "First"))

        let events = decoder.decode(summaryDelta(index: 1, delta: "Second")).map(\.event)

        XCTAssertEqual(events, [
            reasoning(text: "\n\n", kind: "summary", index: 1),
            reasoning(text: "Second", kind: "summary", index: 1)
        ])
    }

    func testNewReasoningItemOpensSectionWithParagraphBreak() {
        // Codex restarts `summaryIndex` at zero for each reasoning item, so the item id is the only
        // thing that changes between two consecutive single-part sections.
        _ = decoder.decode(summaryDelta(itemId: "reasoning-1", index: 0, delta: "First"))

        let events = decoder.decode(summaryDelta(itemId: "reasoning-2", index: 0, delta: "Second")).map(\.event)

        XCTAssertEqual(events, [
            reasoning(text: "\n\n", itemId: "reasoning-2", kind: "summary", index: 0),
            reasoning(text: "Second", itemId: "reasoning-2", kind: "summary", index: 0)
        ])
    }

    func testSwitchingFromContentToSummaryOpensSectionWithParagraphBreak() {
        _ = decoder.decode(contentDelta(index: 0, delta: "Private"))

        let events = decoder.decode(summaryDelta(index: 0, delta: "Public")).map(\.event)

        XCTAssertEqual(events, [
            reasoning(text: "\n\n", kind: "summary", index: 0),
            reasoning(text: "Public", kind: "summary", index: 0)
        ])
    }

    func testConsecutiveDeltasInOneSectionEmitNoBreak() {
        _ = decoder.decode(summaryDelta(index: 0, delta: "Sum"))

        let events = decoder.decode(summaryDelta(index: 0, delta: "mary")).map(\.event)

        XCTAssertEqual(events, [reasoning(text: "mary", kind: "summary", index: 0)])
    }

    func testInterveningToolItemResetsTheSection() {
        _ = decoder.decode(summaryDelta(itemId: "reasoning-1", index: 0, delta: "First"))
        _ = decoder.decode(itemCompleted(item: [
            "id": .string("command-1"),
            "type": .string("commandExecution"),
            "command": .string("swift test")
        ]))

        let events = decoder.decode(summaryDelta(itemId: "reasoning-2", index: 0, delta: "Second")).map(\.event)

        XCTAssertEqual(events, [reasoning(text: "Second", itemId: "reasoning-2", kind: "summary", index: 0)])
    }

    func testTurnStartResetsTheSection() {
        _ = decoder.decode(summaryDelta(itemId: "reasoning-1", index: 0, delta: "First"))
        _ = decoder.decode(notification(method: "turn/started", params: [
            "threadId": .string("thread-1"),
            "turn": .object(["id": .string("turn-2")])
        ]))

        let events = decoder.decode(summaryDelta(itemId: "reasoning-2", index: 0, delta: "Second")).map(\.event)

        XCTAssertEqual(events, [reasoning(text: "Second", itemId: "reasoning-2", kind: "summary", index: 0)])
    }

    func testInterleavedThreadsTrackSectionsIndependently() {
        // One decoder serves every thread in the process; another thread's reasoning must not read
        // as a section change for this one.
        _ = decoder.decode(summaryDelta(threadId: "thread-1", itemId: "reasoning-1", index: 0, delta: "A"))
        _ = decoder.decode(summaryDelta(threadId: "thread-2", itemId: "reasoning-9", index: 0, delta: "B"))

        let events = decoder.decode(summaryDelta(threadId: "thread-1", itemId: "reasoning-1", index: 0, delta: "A2")).map(\.event)

        XCTAssertEqual(events, [reasoning(text: "A2", kind: "summary", index: 0)])
    }

    func testSummaryPartAddedEmitsNoEvents() {
        // The part lifecycle notification carries no text and no longer drives section boundaries.
        let events = decoder.decode(notification(method: "item/reasoning/summaryPartAdded", params: [
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "itemId": .string("reasoning-1"),
            "summaryIndex": .number(1),
            "text": .string("")
        ])).map(\.event)

        XCTAssertEqual(events, [])
    }

    func testCompletedReasoningJoinsPartsWithParagraphBreaks() {
        let events = decoder.decode(itemCompleted(item: [
            "id": .string("reasoning-1"),
            "type": .string("reasoning"),
            "summary": .array([.string("First"), .string("Second")])
        ])).map(\.event)

        XCTAssertEqual(events, [
            .reasoning(AgentReasoningEvent(
                text: "First\n\nSecond",
                metadata: itemMetadata(
                    method: "item/completed",
                    itemId: "reasoning-1",
                    values: [
                        "codex_item_type": .string("reasoning"),
                        "codex_item_phase": .string("completed"),
                        "completed_at_ms": .number(2),
                        "codex_reasoning_kind": .string("summary")
                    ]
                )
            ))
        ])
    }

    private func summaryDelta(
        threadId: String = "thread-1",
        itemId: String = "reasoning-1",
        index: Double,
        delta: String
    ) -> CodexAppServerNotification {
        notification(method: "item/reasoning/summaryTextDelta", params: [
            "threadId": .string(threadId),
            "turnId": .string("turn-1"),
            "itemId": .string(itemId),
            "summaryIndex": .number(index),
            "delta": .string(delta)
        ])
    }

    private func contentDelta(itemId: String = "reasoning-1", index: Double, delta: String) -> CodexAppServerNotification {
        notification(method: "item/reasoning/textDelta", params: [
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "itemId": .string(itemId),
            "contentIndex": .number(index),
            "delta": .string(delta)
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

    private func reasoning(
        text: String,
        itemId: String = "reasoning-1",
        kind: String,
        index: Double
    ) -> AgentEvent {
        .reasoning(AgentReasoningEvent(
            text: text,
            metadata: itemMetadata(
                method: kind == "summary" ? "item/reasoning/summaryTextDelta" : "item/reasoning/textDelta",
                itemId: itemId,
                values: [
                    "codex_reasoning_kind": .string(kind),
                    "codex_reasoning_index": .number(index)
                ]
            )
        ))
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

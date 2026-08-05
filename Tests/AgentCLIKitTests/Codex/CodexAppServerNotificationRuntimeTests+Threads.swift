import XCTest

@testable import AgentCLIKit

/// Compaction, model, review-mode, and thread-goal notification decoding.
extension CodexAppServerNotificationRuntimeTests {
    // swiftlint:disable:next function_body_length
    func testDecodesCompactionAndModelNotifications() {
        let compactedEvents = decoder.decode(notification(
            method: "thread/compacted",
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1")
            ]
        )).map(\.event)
        let reroutedEvents = decoder.decode(notification(
            method: "model/rerouted",
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "fromModel": .string("model-a"),
                "toModel": .string("model-b"),
                "reason": .string("highRiskCyberActivity")
            ]
        )).map(\.event)
        let verificationEvents = decoder.decode(notification(
            method: "model/verification",
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "verifications": .array([.string("trustedAccessForCyber")])
            ]
        )).map(\.event)

        XCTAssertEqual(compactedEvents, [
            .contextCompaction(AgentContextCompactionEvent(
                id: "codex-context-compaction-turn-1",
                phase: .completed,
                metadata: itemMetadata(method: "thread/compacted", itemId: nil)
            ))
        ])
        XCTAssertEqual(reroutedEvents, [
            .diagnostic(AgentDiagnosticEvent(
                severity: .info,
                message: "Codex rerouted the model for this turn.",
                metadata: itemMetadata(
                    method: "model/rerouted",
                    itemId: nil,
                    values: [
                        "from_model": .string("model-a"),
                        "to_model": .string("model-b"),
                        "reason": .string("highRiskCyberActivity")
                    ]
                )
            ))
        ])
        XCTAssertEqual(verificationEvents, [
            .diagnostic(AgentDiagnosticEvent(
                severity: .info,
                message: "Codex verified model access requirements.",
                metadata: itemMetadata(
                    method: "model/verification",
                    itemId: nil,
                    values: ["verifications": .array([.string("trustedAccessForCyber")])]
                )
            ))
        ])
    }

    func testIgnoresUnsupportedReviewModeNotifications() {
        let events = decoder.decode(notification(
            method: "review/session/updated",
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "status": .string("active")
            ]
        ))

        XCTAssertEqual(events.map(\.event), [])
    }

    func testDecodesThreadGoalUpdatedNotification() {
        let events = decoder.decode(notification(
            method: "thread/goal/updated",
            params: [
                "threadId": .string("thread-1"),
                "goal": .object([
                    "threadId": .string("thread-1"),
                    "objective": .string("Ship goal mode"),
                    "status": .string("completed"),
                    "tokensUsed": .number(123),
                    "timeUsedSeconds": .number(9)
                ])
            ]
        )).map(\.event)

        XCTAssertEqual(events, [
            .goal(AgentGoalEvent(snapshot: AgentGoalSnapshot(
                objective: "Ship goal mode",
                status: .achieved,
                availableActions: [],
                elapsedSeconds: 9,
                tokenCount: 123,
                metadata: [
                    "codex_goal_status": .string("completed"),
                    "codex_goal": .object([
                        "threadId": .string("thread-1"),
                        "objective": .string("Ship goal mode"),
                        "status": .string("completed"),
                        "tokensUsed": .number(123),
                        "timeUsedSeconds": .number(9)
                    ]),
                    "codex_thread_id": .string("thread-1"),
                    "codex_method": .string("thread/goal/updated")
                ]
            )))
        ])
    }

    func testDecodesThreadGoalClearedNotification() {
        let events = decoder.decode(notification(
            method: "thread/goal/cleared",
            params: ["threadId": .string("thread-1")]
        )).map(\.event)

        XCTAssertEqual(events, [
            .goal(.cleared(metadata: [
                "codex_method": .string("thread/goal/cleared"),
                "codex_thread_id": .string("thread-1")
            ]))
        ])
    }

    func notification(method: String, params: [String: JSONValue]) -> CodexAppServerNotification {
        CodexAppServerNotification(method: method, params: .object(params))
    }

    func itemMetadata(
        method: String,
        itemId: String? = "item-1",
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

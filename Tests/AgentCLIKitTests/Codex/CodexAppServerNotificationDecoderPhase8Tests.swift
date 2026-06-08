import XCTest

@testable import AgentCLIKit

final class CodexNotificationPhase8Tests: XCTestCase {
    private let decoder = CodexAppServerNotificationDecoder()

    // swiftlint:disable:next function_body_length
    func testDecodesTokenUsageAsInterimUsageEvent() {
        let events = decoder.decode(notification(
            method: "thread/tokenUsage/updated",
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "tokenUsage": .object([
                    "last": .object([
                        "inputTokens": .number(2),
                        "cachedInputTokens": .number(1),
                        "outputTokens": .number(3),
                        "reasoningOutputTokens": .number(4),
                        "totalTokens": .number(10)
                    ]),
                    "total": .object([
                        "inputTokens": .number(20),
                        "cachedInputTokens": .number(5),
                        "outputTokens": .number(30),
                        "reasoningOutputTokens": .number(7),
                        "totalTokens": .number(62)
                    ]),
                    "modelContextWindow": .number(200_000)
                ])
            ]
        )).map(\.event)

        guard case let .usage(usage)? = events.first else {
            return XCTFail("Expected usage event")
        }
        XCTAssertNil(usage.cacheReadInputTokens)

        XCTAssertEqual(events, [
            .usage(AgentUsageEvent(
                model: nil,
                inputTokens: 2,
                outputTokens: 3,
                cachedInputTokens: 1,
                totalTokens: 10,
                contextWindow: 200_000,
                stopReason: AgentUsageEvent.interimUsageStopReason,
                metadata: [
                    "codex_method": .string("thread/tokenUsage/updated"),
                    "codex_thread_id": .string("thread-1"),
                    "codex_turn_id": .string("turn-1"),
                    "stop_reason": .string(AgentUsageEvent.interimUsageStopReason),
                    "input_tokens": .number(2),
                    "output_tokens": .number(3),
                    "cached_input_tokens": .number(1),
                    "reasoning_output_tokens": .number(4),
                    "total_tokens": .number(10),
                    "context_window": .number(200_000),
                    "codex_last_token_usage": .object([
                        "inputTokens": .number(2),
                        "cachedInputTokens": .number(1),
                        "outputTokens": .number(3),
                        "reasoningOutputTokens": .number(4),
                        "totalTokens": .number(10)
                    ]),
                    "codex_total_token_usage": .object([
                        "inputTokens": .number(20),
                        "cachedInputTokens": .number(5),
                        "outputTokens": .number(30),
                        "reasoningOutputTokens": .number(7),
                        "totalTokens": .number(62)
                    ])
                ]
            ))
        ])
    }

    // swiftlint:disable:next function_body_length
    func testTokenUsageFallsBackToTotalUsageWhenLastUsageIsUnavailable() {
        let events = decoder.decode(notification(
            method: "thread/tokenUsage/updated",
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "tokenUsage": .object([
                    "total": .object([
                        "inputTokens": .number(20),
                        "cachedInputTokens": .number(5),
                        "outputTokens": .number(30),
                        "reasoningOutputTokens": .number(7),
                        "totalTokens": .number(62)
                    ]),
                    "modelContextWindow": .number(200_000)
                ])
            ]
        )).map(\.event)

        guard case let .usage(usage)? = events.first else {
            return XCTFail("Expected usage event")
        }
        XCTAssertNil(usage.cacheReadInputTokens)

        XCTAssertEqual(events, [
            .usage(AgentUsageEvent(
                model: nil,
                inputTokens: 20,
                outputTokens: 30,
                cachedInputTokens: 5,
                totalTokens: 62,
                contextWindow: 200_000,
                stopReason: AgentUsageEvent.interimUsageStopReason,
                metadata: [
                    "codex_method": .string("thread/tokenUsage/updated"),
                    "codex_thread_id": .string("thread-1"),
                    "codex_turn_id": .string("turn-1"),
                    "stop_reason": .string(AgentUsageEvent.interimUsageStopReason),
                    "input_tokens": .number(20),
                    "output_tokens": .number(30),
                    "cached_input_tokens": .number(5),
                    "reasoning_output_tokens": .number(7),
                    "total_tokens": .number(62),
                    "context_window": .number(200_000),
                    "codex_total_token_usage": .object([
                        "inputTokens": .number(20),
                        "cachedInputTokens": .number(5),
                        "outputTokens": .number(30),
                        "reasoningOutputTokens": .number(7),
                        "totalTokens": .number(62)
                    ])
                ]
            ))
        ])
    }

    func testThreadCompactStartIsNotAProviderCompactionEvent() {
        let events = decoder.decode(notification(
            method: "thread/compact/start",
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1")
            ]
        )).map(\.event)

        XCTAssertEqual(events, [])
    }

    // swiftlint:disable:next function_body_length
    func testDecodesRateLimitSnapshot() {
        let events = decoder.decode(notification(
            method: "account/rateLimits/updated",
            params: [
                "rateLimits": .object([
                    "limitId": .string("primary"),
                    "limitName": .string("Primary"),
                    "planType": .string("plus"),
                    "primary": .object([
                        "usedPercent": .number(85),
                        "resetsAt": .number(1_700_000_000_000),
                        "windowDurationMins": .number(300)
                    ]),
                    "secondary": .null,
                    "credits": .object([
                        "hasCredits": .bool(true),
                        "unlimited": .bool(false),
                        "balance": .string("10")
                    ])
                ])
            ]
        )).map(\.event)

        XCTAssertEqual(events, [
            .rateLimit(AgentRateLimitEvent(
                status: .allowedWarning,
                resetDate: Date(timeIntervalSince1970: 1_700_000_000),
                limitType: "primary",
                utilization: 0.85,
                metadata: [
                    "codex_method": .string("account/rateLimits/updated"),
                    "codex_rate_limits": .object([
                        "limitId": .string("primary"),
                        "limitName": .string("Primary"),
                        "planType": .string("plus"),
                        "primary": .object([
                            "usedPercent": .number(85),
                            "resetsAt": .number(1_700_000_000_000),
                            "windowDurationMins": .number(300)
                        ]),
                        "secondary": .null,
                        "credits": .object([
                            "hasCredits": .bool(true),
                            "unlimited": .bool(false),
                            "balance": .string("10")
                        ])
                    ]),
                    "limit_id": .string("primary"),
                    "limit_name": .string("Primary"),
                    "plan_type": .string("plus"),
                    "used_percent": .number(85),
                    "resets_at": .number(1_700_000_000_000)
                ]
            ))
        ])
    }

    // swiftlint:disable:next function_body_length
    func testDecodesPlanUpdateAndDeltaAsTaskEvents() {
        let planEvents = decoder.decode(notification(
            method: "turn/plan/updated",
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "explanation": .string("Working plan"),
                "plan": .array([
                    .object(["step": .string("Inspect"), "status": .string("completed")]),
                    .object(["step": .string("Implement"), "status": .string("inProgress")]),
                    .object(["step": .string("Test"), "status": .string("pending")])
                ])
            ]
        )).map(\.event)
        let deltaEvents = decoder.decode(notification(
            method: "item/plan/delta",
            params: [
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("plan-item-1"),
                "delta": .string("Implement")
            ]
        )).map(\.event)

        XCTAssertEqual(planEvents, [
            .task(AgentTaskEvent(
                id: "codex-plan-turn-1",
                phase: .progress,
                description: "Working plan",
                taskType: "plan",
                status: "updated",
                metadata: [
                    "codex_method": .string("turn/plan/updated"),
                    "codex_thread_id": .string("thread-1"),
                    "codex_turn_id": .string("turn-1"),
                    "explanation": .string("Working plan"),
                    "codex_plan": .array([
                        .object(["step": .string("Inspect"), "status": .string("completed")]),
                        .object(["step": .string("Implement"), "status": .string("inProgress")]),
                        .object(["step": .string("Test"), "status": .string("pending")])
                    ]),
                    "todos": .array([
                        .object([
                            "id": .string("codex-plan-turn-1-0"),
                            "subject": .string("Inspect"),
                            "status": .string("completed")
                        ]),
                        .object([
                            "id": .string("codex-plan-turn-1-1"),
                            "subject": .string("Implement"),
                            "status": .string("inProgress")
                        ]),
                        .object([
                            "id": .string("codex-plan-turn-1-2"),
                            "subject": .string("Test"),
                            "status": .string("pending")
                        ])
                    ])
                ]
            ))
        ])
        XCTAssertEqual(deltaEvents, [
            .task(AgentTaskEvent(
                id: "plan-item-1",
                phase: .progress,
                description: "Implement",
                taskType: "plan",
                status: "streaming",
                metadata: [
                    "codex_method": .string("item/plan/delta"),
                    "codex_thread_id": .string("thread-1"),
                    "codex_turn_id": .string("turn-1"),
                    "codex_item_id": .string("plan-item-1"),
                    "codex_plan_delta": .string("Implement")
                ]
            ))
        ])
    }

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

    private func notification(method: String, params: [String: JSONValue]) -> CodexAppServerNotification {
        CodexAppServerNotification(method: method, params: .object(params))
    }

    private func itemMetadata(
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

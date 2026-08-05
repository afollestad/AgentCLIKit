import XCTest

@testable import AgentCLIKit

final class CodexAppServerNotificationRuntimeTests: XCTestCase {
    var decoder = CodexAppServerNotificationDecoder()

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

}

import XCTest

@testable import AgentCLIKit

final class ClaudeStreamDecoderStatusTests: XCTestCase {
    func testResultUsageMatchesModelUsageContextWindow() throws {
        let events = try ClaudeStreamDecoder().decodeLine(Self.modelUsageResultLine)

        XCTAssertTrue(events.contains {
            $0 == .usage(AgentUsageEvent(
                model: "opus",
                inputTokens: 10,
                outputTokens: 5,
                cacheReadInputTokens: 2,
                cacheCreationInputTokens: 1,
                durationMs: 1234,
                costUSD: 0.25,
                contextWindow: 200000,
                stopReason: "end_turn",
                isTerminal: true,
                metadata: [
                    "cache_read_input_tokens": .number(2),
                    "cache_creation_input_tokens": .number(1),
                    "stop_reason": .string("end_turn"),
                    "duration_ms": .number(1234),
                    "total_cost_usd": .number(0.25),
                    "context_window": .number(200000)
                ]
            ))
        })
    }

    func testResultUsageMatchesModelUsageWhenOptionalZeroFieldsAreOmitted() throws {
        let events = try ClaudeStreamDecoder().decodeLine(Self.modelUsageWithOmittedZeroFieldsLine)

        XCTAssertTrue(events.contains {
            $0 == .usage(AgentUsageEvent(
                model: "claude-sonnet-4-6",
                inputTokens: 10,
                outputTokens: 2,
                cacheReadInputTokens: nil,
                cacheCreationInputTokens: nil,
                durationMs: 42,
                costUSD: 0.01,
                contextWindow: 200_000,
                stopReason: "end_turn",
                isTerminal: true,
                metadata: [
                    "stop_reason": .string("end_turn"),
                    "is_error": .bool(false),
                    "duration_ms": .number(42),
                    "total_cost_usd": .number(0.01),
                    "context_window": .number(200_000)
                ]
            ))
        })
    }

    func testResultToolDeferredEmitsApprovalInteraction() throws {
        let events = try ClaudeStreamDecoder().decodeLine(Self.deferredToolResultLine)

        XCTAssertTrue(events.contains {
            $0 == .interaction(AgentInteractionEvent(
                id: "tool-1",
                kind: .approval,
                prompt: "Edit",
                metadata: [
                    "tool_name": .string("Edit"),
                    "tool_input": .object(["file_path": .string("README.md")]),
                    "session_id": .string("session-123")
                ]
            ))
        })
        XCTAssertTrue(events.contains { $0 == .usage(AgentUsageEvent(
            model: nil,
            inputTokens: 1,
            outputTokens: 2,
            stopReason: "tool_deferred",
            isTerminal: true,
            metadata: ["stop_reason": .string("tool_deferred")]
        )) })
    }

    func testResultToolDeferredClassifiesAskUserQuestionAsPrompt() throws {
        let events = try ClaudeStreamDecoder().decodeLine(Self.deferredAskUserQuestionResultLine)

        XCTAssertTrue(events.contains {
            $0 == .interaction(AgentInteractionEvent(
                id: "tool-2",
                kind: .prompt,
                prompt: "AskUserQuestion",
                metadata: [
                    "tool_name": .string("AskUserQuestion"),
                    "tool_input": .object(["questions": .array([])]),
                    "session_id": .string("session-123")
                ]
            ))
        })
    }

    func testSystemTaskEventsExposeSubAgentMetadata() throws {
        let events = try ClaudeStreamDecoder().decodeLine(Self.taskProgressLine)

        XCTAssertEqual(events, [
            .task(AgentTaskEvent(
                id: "task-1",
                phase: .progress,
                description: "Review files",
                lastToolName: "Read",
                toolUses: 3,
                totalTokens: 400,
                durationMs: 250,
                metadata: [
                    "tool_use_id": .string("task-1"),
                    "description": .string("Review files"),
                    "last_tool_name": .string("Read"),
                    "tool_uses": .number(3),
                    "total_tokens": .number(400),
                    "duration_ms": .number(250)
                ]
            ))
        ])
    }

    func testDecodesPermissionModeAndPermissionDenials() throws {
        let decoder = ClaudeStreamDecoder()
        let system = try decoder.decodeLine(#"{"type":"system","subtype":"status","permissionMode":"plan"}"#)
        let result = try decoder.decodeLine(Self.permissionDeniedResultLine)

        XCTAssertTrue(system.contains { $0 == .permissionMode(AgentPermissionModeEvent(mode: "plan")) })
        XCTAssertTrue(result.contains { $0 == .usage(AgentUsageEvent(
            model: nil,
            inputTokens: 1,
            outputTokens: 0,
            stopReason: "permission_denial",
            isTerminal: true,
            isError: true,
            permissionDenials: [AgentPermissionDenialSummary(toolUseId: "tool-1", toolName: "Bash", reason: "Denied")],
            metadata: [
                "stop_reason": .string("permission_denial"),
                "is_error": .bool(true)
            ]
        )) })
    }

    func testRateLimitEventDecodesProviderStatus() throws {
        let events = try ClaudeStreamDecoder().decodeLine(Self.rateLimitLine)

        XCTAssertEqual(events, [
            .rateLimit(AgentRateLimitEvent(
                status: .allowedWarning,
                resetDate: Date(timeIntervalSince1970: 1_779_375_000),
                limitType: "five_hour",
                utilization: 0.82,
                overageStatus: .rejected,
                overageResetDate: Date(timeIntervalSince1970: 1_779_465_000),
                overageDisabledReason: "team_disabled",
                metadata: [
                    "status": .string("allowed_warning"),
                    "resets_at": .number(1_779_375_000),
                    "rate_limit_type": .string("five_hour"),
                    "utilization": .number(0.82),
                    "overage_status": .string("rejected"),
                    "overage_resets_at": .number(1_779_465_000),
                    "overage_disabled_reason": .string("team_disabled"),
                    "uuid": .string("event-1"),
                    "session_id": .string("session-123")
                ]
            ))
        ])
    }

    func testRateLimitEventIgnoresUnrelatedShapeChanges() throws {
        let events = try ClaudeStreamDecoder().decodeLine(Self.rateLimitWithUnexpectedResultLine)

        XCTAssertEqual(events, [
            .rateLimit(AgentRateLimitEvent(
                status: .allowed,
                resetDate: Date(timeIntervalSince1970: 1_779_375_000),
                utilization: 0.12,
                metadata: [
                    "status": .string("allowed"),
                    "resets_at": .number(1_779_375_000),
                    "utilization": .number(0.12)
                ]
            ))
        ])
    }

    private static let modelUsageResultLine = #"""
    {
      "type": "result",
      "subtype": "success",
      "stop_reason": "end_turn",
      "duration_ms": 1234,
      "total_cost_usd": 0.25,
      "usage": {
        "input_tokens": 10,
        "output_tokens": 5,
        "cache_read_input_tokens": 2,
        "cache_creation_input_tokens": 1
      },
      "modelUsage": {
        "small": {
          "inputTokens": 1,
          "outputTokens": 1,
          "cacheReadInputTokens": 0,
          "cacheCreationInputTokens": 0,
          "contextWindow": 1000
        },
        "opus": {
          "inputTokens": 10,
          "outputTokens": 5,
          "cacheReadInputTokens": 2,
          "cacheCreationInputTokens": 1,
          "contextWindow": 200000
        }
      }
    }
    """#

    private static let modelUsageWithOmittedZeroFieldsLine = #"""
    {
      "type": "result",
      "stop_reason": "end_turn",
      "is_error": false,
      "usage": {
        "input_tokens": 10,
        "output_tokens": 2
      },
      "duration_ms": "42",
      "total_cost_usd": "0.01",
      "modelUsage": {
        "claude-opus-4-7": {
          "inputTokens": 100,
          "outputTokens": 20,
          "cacheReadInputTokens": 10,
          "cacheCreationInputTokens": 10,
          "contextWindow": 1000000
        },
        "claude-sonnet-4-6": {
          "inputTokens": 10,
          "outputTokens": 2,
          "contextWindow": 200000
        }
      }
    }
    """#

    private static let deferredToolResultLine = #"""
    {
      "type": "result",
      "session_id": "session-123",
      "stop_reason": "tool_deferred",
      "deferred_tool_use": {
        "id": "tool-1",
        "name": "Edit",
        "input": {"file_path": "README.md"}
      },
      "usage": {"input_tokens": 1, "output_tokens": 2}
    }
    """#

    private static let deferredAskUserQuestionResultLine = #"""
    {
      "type": "result",
      "session_id": "session-123",
      "stop_reason": "tool_deferred",
      "deferred_tool_use": {
        "id": "tool-2",
        "name": "AskUserQuestion",
        "input": {"questions": []}
      },
      "usage": {"input_tokens": 1, "output_tokens": 2}
    }
    """#

    private static let taskProgressLine = #"""
    {
      "type": "system",
      "subtype": "task_progress",
      "tool_use_id": "task-1",
      "description": "Review files",
      "last_tool_name": "Read",
      "usage": {
        "tool_uses": 3,
        "total_tokens": 400,
        "duration_ms": 250
      }
    }
    """#

    private static let permissionDeniedResultLine = #"""
    {
      "type": "result",
      "subtype": "error",
      "stop_reason": "permission_denial",
      "usage": {"input_tokens": 1, "output_tokens": 0},
      "permission_denials": [{"tool_use_id": "tool-1", "tool_name": "Bash", "reason": "Denied"}]
    }
    """#

    private static let rateLimitLine = #"""
    {
      "type": "rate_limit_event",
      "uuid": "event-1",
      "session_id": "session-123",
      "rate_limit_info": {
        "status": "allowed_warning",
        "resetsAt": 1779375000000,
        "rateLimitType": "five_hour",
        "utilization": 0.82,
        "overageStatus": "rejected",
        "overageResetsAt": 1779465000000,
        "overageDisabledReason": "team_disabled"
      }
    }
    """#

    private static let rateLimitWithUnexpectedResultLine = #"""
    {
      "type": "rate_limit_event",
      "result": {"unexpected": true},
      "rate_limit_info": {
        "status": "allowed",
        "resets_at": 1779375000,
        "utilization": 0.12
      }
    }
    """#
}

import XCTest

@testable import AgentCLIKit

final class ClaudeStreamDecoderTests: XCTestCase {
    func testDecodesSystemAndUsageEvents() throws {
        let decoder = ClaudeStreamDecoder()

        let system = try decoder.decodeLine(#"{"type":"system","subtype":"init","session_id":"abc","model":"sonnet"}"#)
        let result = try decoder.decodeLine(
            #"{"type":"result","subtype":"success","result":"Done","model":"sonnet","usage":{"input_tokens":10,"output_tokens":5}}"#
        )

        XCTAssertTrue(system.contains {
            guard case let .diagnostic(diagnostic) = $0 else {
                return false
            }
            return diagnostic.metadata["session_id"] == .string("abc")
        })
        XCTAssertTrue(result.contains { $0 == .message(AgentMessageEvent(role: .assistant, text: "Done")) })
        XCTAssertTrue(result.contains { $0 == .usage(AgentUsageEvent(model: "sonnet", inputTokens: 10, outputTokens: 5)) })
    }

    func testDecodesAssistantMessageUsageEvent() throws {
        let decoder = ClaudeStreamDecoder()
        let line = #"""
        {
          "type": "assistant",
          "model": "sonnet",
          "message": {
            "role": "assistant",
            "content": [{"type": "text", "text": "Working"}],
            "usage": {
              "input_tokens": 12,
              "output_tokens": 3,
              "cache_read_input_tokens": 4,
              "cache_creation_input_tokens": 5
            }
          }
        }
        """#

        let events = try decoder.decodeLine(line)

        XCTAssertTrue(events.contains { $0 == .message(AgentMessageEvent(role: .assistant, text: "Working")) })
        XCTAssertTrue(events.contains {
            $0 == .usage(AgentUsageEvent(
                model: "sonnet",
                inputTokens: 12,
                outputTokens: 3,
                metadata: [
                    "cache_read_input_tokens": .number(4),
                    "cache_creation_input_tokens": .number(5)
                ]
            ))
        })
    }

    func testDecodesStreamDeltaAndThinkingEvents() throws {
        let decoder = ClaudeStreamDecoder()
        let delta = #"""
        {
          "type": "stream_event",
          "parent_tool_use_id": "task-1",
          "event": {
            "type": "content_block_delta",
            "delta": {
              "type": "text_delta",
              "text": "Hel"
            }
          }
        }
        """#
        let thinking = #"""
        {
          "type": "assistant",
          "parent_tool_use_id": "task-1",
          "message": {
            "role": "assistant",
            "content": [{"type": "thinking", "thinking": "Reasoning"}]
          }
        }
        """#

        let deltaEvents = try decoder.decodeLine(delta)
        let thinkingEvents = try decoder.decodeLine(thinking)

        XCTAssertEqual(deltaEvents, [
            .messageDelta(AgentMessageDeltaEvent(
                role: .assistant,
                text: "Hel",
                metadata: ["parent_tool_use_id": .string("task-1")]
            ))
        ])
        XCTAssertEqual(thinkingEvents, [
            .reasoning(AgentReasoningEvent(
                text: "Reasoning",
                metadata: ["parent_tool_use_id": .string("task-1")]
            ))
        ])
    }

    func testResultUsageMatchesModelUsageContextWindow() throws {
        let decoder = ClaudeStreamDecoder()
        let line = #"""
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

        let events = try decoder.decodeLine(line)

        XCTAssertTrue(events.contains {
            $0 == .usage(AgentUsageEvent(
                model: "opus",
                inputTokens: 10,
                outputTokens: 5,
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

    func testResultToolDeferredEmitsApprovalInteraction() throws {
        let decoder = ClaudeStreamDecoder()
        let line = #"""
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

        let events = try decoder.decodeLine(line)

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
            metadata: ["stop_reason": .string("tool_deferred")]
        )) })
    }

    func testSystemTaskEventsExposeSubAgentMetadata() throws {
        let decoder = ClaudeStreamDecoder()
        let line = #"""
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

        let events = try decoder.decodeLine(line)

        XCTAssertEqual(events, [
            .diagnostic(AgentDiagnosticEvent(
                severity: .info,
                message: "task_progress",
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

    func testDecodesMessageAndToolUseEventsWithMetadata() throws {
        let decoder = ClaudeStreamDecoder()
        let assistant = #"""
        {
          "type": "assistant",
          "parent_tool_use_id": "agent-tool-1",
          "message": {
            "role": "assistant",
            "content": [
              {"type": "text", "text": "Working"},
              {
                "type": "tool_use",
                "id": "tool-1",
                "name": "Edit",
                "input": {"file_path": "README.md"},
                "caller": {"type": "agent", "agent": "reviewer"}
              }
            ]
          }
        }
        """#

        let assistantEvents = try decoder.decodeLine(assistant)

        XCTAssertTrue(assistantEvents.contains {
            $0 == .message(AgentMessageEvent(
                role: .assistant,
                text: "Working",
                metadata: ["parent_tool_use_id": .string("agent-tool-1")]
            ))
        })
        XCTAssertTrue(assistantEvents.contains {
            $0 == .toolCall(AgentToolCallEvent(
                id: "tool-1",
                name: "Edit",
                input: .object(["file_path": .string("README.md")]),
                metadata: [
                    "parent_tool_use_id": .string("agent-tool-1"),
                    "caller_agent": .string("reviewer")
                ]
            ))
        })
    }

    func testDecodesToolResultEventsWithMetadata() throws {
        let decoder = ClaudeStreamDecoder()
        let user = #"""
        {
          "type": "user",
          "parent_tool_use_id": "agent-tool-1",
          "message": {
            "role": "user",
            "content": [{"type":"tool_result","tool_use_id":"tool-1","is_error":false}]
          },
          "tool_use_result": {
            "stdout": "ok",
            "stderr": "stderr text",
            "interrupted": true,
            "isImage": false,
            "noOutputExpected": true
          }
        }
        """#

        let userEvents = try decoder.decodeLine(user)

        XCTAssertEqual(userEvents, [.toolResult(AgentToolResultEvent(
            id: "tool-1",
            isError: false,
            content: "ok",
            metadata: [
                "parent_tool_use_id": .string("agent-tool-1"),
                "stderr": .string("stderr text"),
                "interrupted": .bool(true),
                "is_image": .bool(false),
                "no_output_expected": .bool(true)
            ]
        ))])
    }

    func testMalformedToolBlocksEmitDiagnostics() throws {
        let decoder = ClaudeStreamDecoder()
        let toolUse = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit"}]}}"#
        let toolResult = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#

        XCTAssertEqual(try decoder.decodeLine(toolUse), [
            .diagnostic(AgentDiagnosticEvent(
                severity: .error,
                message: "Malformed Claude event: missing tool_use id or name in assistant block"
            ))
        ])
        XCTAssertEqual(try decoder.decodeLine(toolResult), [
            .diagnostic(AgentDiagnosticEvent(
                severity: .error,
                message: "Malformed Claude event: missing tool_use_id in tool_result"
            ))
        ])
    }

    func testStripsCaveatAndDecodesInterruptionAndHookFailure() throws {
        let decoder = ClaudeStreamDecoder()

        let caveat = try decoder.decodeLine(
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Caveat: noisy\nUseful"}]}}"#
        )
        let interrupted = try decoder.decodeLine(#"{"type":"result","subtype":"interrupted"}"#)
        let hookFailure = try decoder.decodeLine(#"{"type":"hook","subtype":"PreToolUse","is_error":true,"result":"denied"}"#)

        XCTAssertEqual(caveat, [.message(AgentMessageEvent(role: .assistant, text: "Useful"))])
        XCTAssertTrue(interrupted.contains { $0 == .lifecycle(AgentLifecycleEvent(state: .cancelled, message: "Claude reported interruption.")) })
        XCTAssertEqual(hookFailure, [.diagnostic(AgentDiagnosticEvent(severity: .error, message: "denied"))])
    }

    func testUserTextMapsToAssistantOutputAndInterruptionMarkerEmitsCancelledLifecycle() throws {
        let decoder = ClaudeStreamDecoder()
        let interrupted = #"""
        {
          "type": "user",
          "message": {
            "role": "user",
            "content": [{"type": "text", "text": " [Request interrupted by user for tool use] "}]
          }
        }
        """#
        let localOutput = #"""
        {
          "type": "user",
          "parent_tool_use_id": "agent-tool-1",
          "message": {
            "role": "user",
            "content": [{"type": "text", "text": " \n<local-command-caveat>\n</local-command-caveat>\nUseful\n "}]
          }
        }
        """#

        XCTAssertEqual(try decoder.decodeLine(interrupted), [
            .lifecycle(AgentLifecycleEvent(state: .cancelled, message: "Interrupted"))
        ])
        XCTAssertEqual(try decoder.decodeLine(localOutput), [
            .message(AgentMessageEvent(
                role: .assistant,
                text: "Useful",
                metadata: ["parent_tool_use_id": .string("agent-tool-1")]
            ))
        ])
    }

    func testThrowsForMalformedStdout() {
        XCTAssertThrowsError(try ClaudeStreamDecoder().decodeLine("{not json"))
    }
}

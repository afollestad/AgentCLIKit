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
        XCTAssertFalse(result.contains {
            if case .message = $0 {
                return true
            }
            return false
        })
        XCTAssertTrue(result.contains { $0 == .usage(AgentUsageEvent(
            model: "sonnet",
            inputTokens: 10,
            outputTokens: 5,
            isTerminal: true
        )) })
    }

    func testResultWithoutUsageStillEmitsTerminalUsageMetadata() throws {
        let decoder = ClaudeStreamDecoder()

        let result = try decoder.decodeLine(#"{"type":"result","subtype":"success","stop_reason":"end_turn","duration_ms":50}"#)

        XCTAssertEqual(result, [
            .usage(AgentUsageEvent(
                model: nil,
                inputTokens: nil,
                outputTokens: nil,
                durationMs: 50,
                stopReason: "end_turn",
                isTerminal: true,
                metadata: [
                    "stop_reason": .string("end_turn"),
                    "duration_ms": .number(50)
                ]
            ))
        ])
    }

    func testResultWithUsageAndNilStopReasonStillEmitsTerminalUsage() throws {
        let decoder = ClaudeStreamDecoder()

        let result = try decoder.decodeLine(
            #"{"type":"result","subtype":"success","duration_ms":50,"usage":{"input_tokens":0,"output_tokens":0}}"#
        )

        XCTAssertEqual(result, [
            .usage(AgentUsageEvent(
                model: nil,
                inputTokens: 0,
                outputTokens: 0,
                durationMs: 50,
                isTerminal: true,
                metadata: [
                    "duration_ms": .number(50)
                ]
            ))
        ])
    }

    func testDecodesAssistantMessageUsageEventAsInterimUsageUpdate() throws {
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
                cacheReadInputTokens: 4,
                cacheCreationInputTokens: 5,
                stopReason: AgentUsageEvent.interimUsageStopReason,
                metadata: [
                    "cache_read_input_tokens": .number(4),
                    "cache_creation_input_tokens": .number(5),
                    "stop_reason": .string(AgentUsageEvent.interimUsageStopReason)
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

    func testDecodesToolResultArrayContentFromToolUseResultBeforeMessageFooter() throws {
        let decoder = ClaudeStreamDecoder()
        let user = #"""
        {
          "type": "user",
          "message": {
            "role": "user",
            "content": [{
              "type": "tool_result",
              "tool_use_id": "toolu_agent",
              "is_error": false,
              "content": [
                {"type": "text", "text": "## Directory Structure Map\n\nFrom message content"},
                {"type": "text", "text": "agentId: agent-1\n<usage>total_tokens: 10</usage>"}
              ]
            }]
          },
          "toolUseResult": {
            "content": [
              {"type": "text", "text": "## Directory Structure Map\n\nFrom clean tool result"}
            ]
          }
        }
        """#

        let events = try decoder.decodeLine(user)

        XCTAssertEqual(events, [.toolResult(AgentToolResultEvent(
            id: "toolu_agent",
            isError: false,
            content: "## Directory Structure Map\n\nFrom clean tool result"
        ))])
    }

    func testDecodesToolResultArrayContentWithoutContinuationFooter() throws {
        let decoder = ClaudeStreamDecoder()
        let user = #"""
        {
          "type": "user",
          "message": {
            "role": "user",
            "content": [{
              "type": "tool_result",
              "tool_use_id": "toolu_agent",
              "is_error": false,
              "content": [
                {"type": "text", "text": "## Directory Structure Map\n\nFrom message content"},
                {"type": "text", "text": "agentId: agent-1\n<usage>total_tokens: 10</usage>"}
              ]
            }]
          }
        }
        """#

        let events = try decoder.decodeLine(user)

        XCTAssertEqual(events, [.toolResult(AgentToolResultEvent(
            id: "toolu_agent",
            isError: false,
            content: "## Directory Structure Map\n\nFrom message content"
        ))])
    }

    func testDecodesCamelCaseToolUseResultTaskMetadata() throws {
        let decoder = ClaudeStreamDecoder()
        let user = #"""
        {
          "type": "user",
          "message": {
            "role": "user",
            "content": [{"type":"tool_result","tool_use_id":"tool-1","is_error":false,"content":"Task #1 created successfully: Read index.html"}]
          },
          "toolUseResult": {
            "task": {
              "id": "1",
              "subject": "Read index.html"
            }
          }
        }
        """#

        let userEvents = try decoder.decodeLine(user)

        XCTAssertEqual(userEvents, [.toolResult(AgentToolResultEvent(
            id: "tool-1",
            isError: false,
            content: "Task #1 created successfully: Read index.html",
            metadata: [
                "task": .object([
                    "id": .string("1"),
                    "subject": .string("Read index.html")
                ])
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

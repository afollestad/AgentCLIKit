import XCTest

@testable import AgentCLIKit

final class ClaudeStreamDecoderAttachmentTests: XCTestCase {
    func testHookAttachmentEventDecodesDeferredTool() throws {
        let decoder = ClaudeStreamDecoder()
        let deferred = #"""
        {
          "type": "attachment",
          "sessionId": "session-123",
          "attachment": {
            "type": "hook_deferred_tool",
            "toolUseID": "tool-1",
            "toolName": "Edit",
            "toolInput": {"file_path": "README.md"}
          }
        }
        """#

        let deferredEvents = try decoder.decodeLine(deferred)

        XCTAssertEqual(deferredEvents, [
            .interaction(AgentInteractionEvent(
                id: "tool-1",
                kind: .approval,
                prompt: "Edit",
                metadata: [
                    "session_id": .string("session-123"),
                    "tool_name": .string("Edit"),
                    "tool_input": .object(["file_path": .string("README.md")])
                ]
            )),
            .usage(AgentUsageEvent(
                model: nil,
                inputTokens: 0,
                outputTokens: 0,
                stopReason: "tool_deferred",
                isTerminal: true,
                metadata: ["stop_reason": .string("tool_deferred")]
            ))
        ])
    }

    func testHookAttachmentEventClassifiesAskUserQuestionAsPrompt() throws {
        let decoder = ClaudeStreamDecoder()
        let deferred = #"""
        {
          "type": "attachment",
          "sessionId": "session-123",
          "attachment": {
            "type": "hook_deferred_tool",
            "toolUseID": "tool-2",
            "toolName": "AskUserQuestion",
            "toolInput": {"questions": []}
          }
        }
        """#

        let deferredEvents = try decoder.decodeLine(deferred)

        XCTAssertTrue(deferredEvents.contains {
            $0 == .interaction(AgentInteractionEvent(
                id: "tool-2",
                kind: .prompt,
                prompt: "AskUserQuestion",
                metadata: [
                    "session_id": .string("session-123"),
                    "tool_name": .string("AskUserQuestion"),
                    "tool_input": .object(["questions": .array([])])
                ]
            ))
        })
    }

    func testHookAttachmentEventDecodesHookFailure() throws {
        let decoder = ClaudeStreamDecoder()
        let failure = #"""
        {
          "type": "attachment",
          "session_id": "session-123",
          "attachment": {
            "type": "hook_non_blocking_error",
            "hookName": "PreToolUse:Edit",
            "tool_use_id": "tool-1",
            "stderr": "denied"
          }
        }
        """#

        let failureEvents = try decoder.decodeLine(failure)

        XCTAssertEqual(failureEvents, [
            .diagnostic(AgentDiagnosticEvent(
                code: .hookApprovalFailed,
                severity: .error,
                message: "Claude hook failed (PreToolUse:Edit): denied",
                metadata: [
                    "hook_name": .string("PreToolUse:Edit"),
                    "session_id": .string("session-123"),
                    "tool_use_id": .string("tool-1"),
                    "tool_name": .string("Edit")
                ]
            ))
        ])
    }

    func testQueuedCommandAttachmentDecodesTaskNotification() throws {
        let decoder = ClaudeStreamDecoder()
        let line = try Self.queuedTaskNotificationLine()

        let events = try decoder.decodeLine(line)

        XCTAssertEqual(events, [
            .subAgent(AgentSubAgentEvent(
                id: "toolu_agent",
                phase: .terminal,
                description: "Agent completed",
                status: "completed",
                result: "Found <script> tags & images.",
                toolUses: 3,
                totalTokens: 14816,
                durationMs: 9929,
                metadata: [
                    "tool_use_id": .string("toolu_agent"),
                    "task_id": .string("async-agent-1"),
                    "summary": .string("Agent completed"),
                    "result": .string("Found <script> tags & images."),
                    "output_file": .string("/tmp/async-agent-1.output"),
                    "status": .string("completed"),
                    "total_tokens": .number(14816),
                    "tool_uses": .number(3),
                    "duration_ms": .number(9929)
                ]
            ))
        ])
    }

    func testGoalStatusAttachmentDecodesActiveGoal() throws {
        let decoder = ClaudeStreamDecoder()
        let line = #"""
        {
          "type": "attachment",
          "session_id": "session-123",
          "attachment": {
            "type": "goal_status",
            "objective": "Ship goal mode",
            "status": "active",
            "elapsedSeconds": 7,
            "tokensUsed": 12
          }
        }
        """#

        let events = try decoder.decodeLine(line)

        XCTAssertEqual(events, [
            .goal(AgentGoalEvent(snapshot: AgentGoalSnapshot(
                objective: "Ship goal mode",
                status: .active,
                availableActions: [.delete],
                elapsedSeconds: 7,
                tokenCount: 12,
                metadata: [
                    "claude_goal_attachment_type": .string("goal_status"),
                    "session_id": .string("session-123"),
                    "claude_goal_status": .string("active")
                ]
            )))
        ])
    }

    func testGoalStatusAttachmentDecodesAchievedGoal() throws {
        let decoder = ClaudeStreamDecoder()
        let line = #"""
        {
          "type": "attachment",
          "session_id": "session-123",
          "attachment": {
            "type": "goal_status",
            "condition": "Make tests pass",
            "met": true,
            "elapsed_seconds": 7,
            "token_count": 12
          }
        }
        """#

        let events = try decoder.decodeLine(line)

        XCTAssertEqual(events, [
            .goal(AgentGoalEvent(snapshot: AgentGoalSnapshot(
                objective: "Make tests pass",
                status: .achieved,
                availableActions: [],
                elapsedSeconds: 7,
                tokenCount: 12,
                metadata: [
                    "claude_goal_attachment_type": .string("goal_status"),
                    "session_id": .string("session-123"),
                    "met": .bool(true)
                ]
            )))
        ])
    }

    func testGoalStatusAttachmentDecodesClearedGoal() throws {
        let decoder = ClaudeStreamDecoder()
        let line = #"""
        {
          "type": "attachment",
          "session_id": "session-123",
          "attachment": {
            "type": "goal_status",
            "goal": "Ship goal mode",
            "cleared": true
          }
        }
        """#

        let events = try decoder.decodeLine(line)

        XCTAssertEqual(events, [
            .goal(.cleared(
                objective: "Ship goal mode",
                metadata: [
                    "claude_goal_attachment_type": .string("goal_status"),
                    "session_id": .string("session-123")
                ]
            ))
        ])
    }

    private static func queuedTaskNotificationLine() throws -> String {
        let content = """
        <task-notification>
        <task-id>async-agent-1</task-id>
        <tool-use-id>toolu_agent</tool-use-id>
        <output-file>/tmp/async-agent-1.output</output-file>
        <status>completed</status>
        <summary>Agent completed</summary>
        <result>Found &lt;script&gt; tags &amp; images.</result>
        <usage><total_tokens>14816</total_tokens><tool_uses>3</tool_uses><duration_ms>9929</duration_ms></usage>
        </task-notification>
        """
        let payload: [String: Any] = [
            "type": "attachment",
            "sessionId": "session-123",
            "attachment": [
                "type": "queued_command",
                "commandMode": "task-notification",
                "prompt": content
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}

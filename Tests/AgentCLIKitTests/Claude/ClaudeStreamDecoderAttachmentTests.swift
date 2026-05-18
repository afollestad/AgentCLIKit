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
                metadata: ["stop_reason": .string("tool_deferred")]
            ))
        ])
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
}

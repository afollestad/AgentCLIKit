import XCTest

@testable import AgentCLIKit

final class ClaudeStreamDecoderTaskOutputTests: XCTestCase {
    func testSystemTaskNotificationPreservesOutputFileMetadata() throws {
        let events = try ClaudeStreamDecoder().decodeLine(Self.systemTaskNotificationLine)

        XCTAssertEqual(events, [
            .task(AgentTaskEvent(
                id: "toolu_agent",
                phase: .notification,
                description: "Agent completed",
                toolUses: 1,
                totalTokens: 200,
                durationMs: 300,
                status: "completed",
                metadata: [
                    "tool_use_id": .string("toolu_agent"),
                    "summary": .string("Agent completed"),
                    "output_file": .string("/tmp/agent-output.jsonl"),
                    "status": .string("completed"),
                    "tool_uses": .number(1),
                    "total_tokens": .number(200),
                    "duration_ms": .number(300)
                ]
            ))
        ])
    }

    private static let systemTaskNotificationLine = #"""
    {
      "type": "system",
      "subtype": "task_notification",
      "tool_use_id": "toolu_agent",
      "status": "completed",
      "output_file": "/tmp/agent-output.jsonl",
      "summary": "Agent completed",
      "usage": {
        "tool_uses": 1,
        "total_tokens": 200,
        "duration_ms": 300
      }
    }
    """#
}

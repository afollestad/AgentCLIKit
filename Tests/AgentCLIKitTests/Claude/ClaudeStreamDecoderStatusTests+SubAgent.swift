import XCTest

@testable import AgentCLIKit

extension ClaudeStreamDecoderStatusTests {
    func testSystemTaskEventsExposeSubAgentMetadata() throws {
        let events = try ClaudeStreamDecoder().decodeLine(Self.taskProgressLine)

        XCTAssertEqual(events, [
            .subAgent(AgentSubAgentEvent(
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

    func testTaskNotificationUserMessageEmitsSubAgentCompletionMetadata() throws {
        let events = try ClaudeStreamDecoder().decodeLine(Self.taskNotificationLine())

        XCTAssertEqual(events, [Self.completedSubAgentEvent()])
    }

    func testTaskNotificationQueueOperationEmitsSubAgentCompletionMetadata() throws {
        let events = try ClaudeStreamDecoder().decodeLine(Self.taskNotificationQueueOperationLine())

        XCTAssertEqual(events, [Self.completedSubAgentEvent()])
    }

    private static func completedSubAgentEvent() -> AgentEvent {
        .subAgent(AgentSubAgentEvent(
            id: "toolu_agent",
            phase: .terminal,
            description: "Agent & docs completed",
            status: "completed",
            result: completedResult,
            toolUses: 2,
            totalTokens: 1234,
            durationMs: 5678,
            metadata: [
                "tool_use_id": .string("toolu_agent"),
                "task_id": .string("async-agent-1"),
                "summary": .string("Agent & docs completed"),
                "result": .string(completedResult),
                "output_file": .string("/tmp/async-agent-1.output"),
                "status": .string("completed"),
                "total_tokens": .number(1234),
                "tool_uses": .number(2),
                "duration_ms": .number(5678)
            ]
        ))
    }

    private static let completedResult = """
    ## Result

    | Name | Value |
    |---|---|
    | HTML | <script>Tom & Jerry</script> |
    """
}

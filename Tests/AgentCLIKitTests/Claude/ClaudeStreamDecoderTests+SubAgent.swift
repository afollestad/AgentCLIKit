import XCTest

@testable import AgentCLIKit

extension ClaudeStreamDecoderTests {
    func testAgentToolUseEmitsSubAgentStartedEvent() throws {
        let decoder = ClaudeStreamDecoder()
        let assistant = #"""
        {
          "type": "assistant",
          "parent_tool_use_id": "parent-tool-1",
          "message": {
            "role": "assistant",
            "content": [
              {
                "type": "tool_use",
                "id": "agent-tool-1",
                "name": "Agent",
                "input": {
                  "description": "Review docs",
                  "prompt": "Check README",
                  "subagent_type": "general-purpose"
                },
                "caller": {"type": "agent", "agent": "planner"}
              }
            ]
          }
        }
        """#

        let assistantEvents = try decoder.decodeLine(assistant)

        XCTAssertEqual(assistantEvents, [
            .subAgent(AgentSubAgentEvent(
                id: "agent-tool-1",
                phase: .started,
                description: "Review docs",
                prompt: "Check README",
                agentType: "general-purpose",
                input: .object([
                    "description": .string("Review docs"),
                    "prompt": .string("Check README"),
                    "subagent_type": .string("general-purpose")
                ]),
                lastToolName: "Agent",
                parentToolUseId: "parent-tool-1",
                callerAgent: "planner",
                metadata: [
                    "parent_tool_use_id": .string("parent-tool-1"),
                    "caller_agent": .string("planner")
                ]
            ))
        ])
    }
}

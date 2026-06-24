import XCTest

@testable import AgentCLIKit

extension ClaudeStreamDecoderTests {
    func testDecodesLiveThinkingDelta() throws {
        let decoder = ClaudeStreamDecoder()
        let line = #"""
        {
          "type": "stream_event",
          "parent_tool_use_id": "task-1",
          "event": {
            "type": "content_block_delta",
            "delta": {
              "type": "thinking_delta",
              "thinking": "Reason"
            }
          }
        }
        """#

        let events = try decoder.decodeLine(line)

        XCTAssertEqual(events, [
            .reasoning(AgentReasoningEvent(
                text: "Reason",
                metadata: ["parent_tool_use_id": .string("task-1")]
            ))
        ])
    }

    func testIgnoresSignatureDelta() throws {
        let decoder = ClaudeStreamDecoder()
        let line = #"""
        {
          "type": "stream_event",
          "event": {
            "type": "content_block_delta",
            "delta": {
              "type": "signature_delta",
              "signature": "abc"
            }
          }
        }
        """#

        let events = try decoder.decodeLine(line)

        XCTAssertEqual(events, [])
    }
}

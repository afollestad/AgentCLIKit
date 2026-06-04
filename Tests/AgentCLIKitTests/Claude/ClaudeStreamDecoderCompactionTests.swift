import XCTest

@testable import AgentCLIKit

final class ClaudeStreamDecoderCompactionTests: XCTestCase {
    // swiftlint:disable:next function_body_length
    func testDecodesContextCompactionStatusAndResultFrames() throws {
        let decoder = ClaudeStreamDecoder()
        let started = try decoder.decodeLine(#"""
        {
          "type": "system",
          "status": "compacting",
          "session_id": "session-123",
          "compact_metadata": {
            "trigger": "auto",
            "pre_tokens": 190000
          }
        }
        """#)
        let completed = try decoder.decodeLine(#"""
        {
          "type": "system",
          "subtype": "compact_boundary",
          "session_id": "session-123",
          "compact_result": "success",
          "compact_metadata": {
            "trigger": "auto",
            "postTokens": 40000,
            "durationMs": 1250
          }
        }
        """#)

        XCTAssertEqual(started, [
            .contextCompaction(AgentContextCompactionEvent(
                id: "claude-context-compaction-session-123-compacting",
                phase: .started,
                trigger: "auto",
                preTokens: 190_000,
                metadata: [
                    "session_id": .string("session-123"),
                    "status": .string("compacting"),
                    "trigger": .string("auto"),
                    "pre_tokens": .number(190_000)
                ]
            ))
        ])
        XCTAssertEqual(completed, [
            .contextCompaction(AgentContextCompactionEvent(
                id: "claude-context-compaction-session-123-compact_boundary",
                phase: .completed,
                trigger: "auto",
                postTokens: 40_000,
                durationMs: 1_250,
                metadata: [
                    "session_id": .string("session-123"),
                    "compact_result": .string("success"),
                    "subtype": .string("compact_boundary"),
                    "trigger": .string("auto"),
                    "post_tokens": .number(40_000),
                    "duration_ms": .number(1_250)
                ]
            ))
        ])
    }

    func testDecodesContextCompactionFailureFrame() throws {
        let events = try ClaudeStreamDecoder().decodeLine(#"""
        {
          "type": "system",
          "session_id": "session-123",
          "compact_result": "failed",
          "compact_error": "Provider reported a compact failure.",
          "compactMetadata": {
            "trigger": "manual",
            "preTokens": 100000
          }
        }
        """#)

        XCTAssertEqual(events, [
            .contextCompaction(AgentContextCompactionEvent(
                id: "claude-context-compaction-session-123-failed",
                phase: .failed,
                trigger: "manual",
                errorMessage: "Provider reported a compact failure.",
                preTokens: 100_000,
                metadata: [
                    "session_id": .string("session-123"),
                    "compact_result": .string("failed"),
                    "compact_error": .string("Provider reported a compact failure."),
                    "trigger": .string("manual"),
                    "pre_tokens": .number(100_000)
                ]
            ))
        ])
    }
}

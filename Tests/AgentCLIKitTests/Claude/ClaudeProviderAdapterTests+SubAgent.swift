import XCTest

@testable import AgentCLIKit

extension ClaudeProviderAdapterTests {
    func testCompletedTaskNotificationReadsResultFromOutputFile() async throws {
        let adapter = ClaudeProviderAdapter()
        let fileURL = try subAgentTaskOutput("""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Detailed sub-agent result"}]}}
        """)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let events = try await adapter.decodeStdoutLine(Self.completedTaskNotificationLine(outputFile: fileURL.path))

        XCTAssertEqual(events, [
            .subAgent(AgentSubAgentEvent(
                id: "toolu_agent",
                phase: .terminal,
                description: "Agent completed",
                status: "completed",
                result: "Detailed sub-agent result",
                toolUses: 1,
                totalTokens: 200,
                durationMs: 300,
                metadata: [
                    "tool_use_id": .string("toolu_agent"),
                    "summary": .string("Agent completed"),
                    "output_file": .string(fileURL.path),
                    "status": .string("completed"),
                    "tool_uses": .number(1),
                    "total_tokens": .number(200),
                    "duration_ms": .number(300),
                    "result": .string("Detailed sub-agent result")
                ]
            ))
        ])
    }

    private func subAgentTaskOutput(_ content: String) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private static func completedTaskNotificationLine(outputFile: String) throws -> String {
        let payload: [String: Any] = [
            "type": "system",
            "subtype": "task_notification",
            "tool_use_id": "toolu_agent",
            "status": "completed",
            "output_file": outputFile,
            "summary": "Agent completed",
            "usage": [
                "tool_uses": 1,
                "total_tokens": 200,
                "duration_ms": 300
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}

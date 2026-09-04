import XCTest

@testable import AgentCLIKit

extension ClaudeStreamDecoderStatusTests {
    func testBackgroundTasksChangedDecodesLiveTaskSet() throws {
        let events = try ClaudeStreamDecoder().decodeLine(#"""
        {"type":"system","subtype":"background_tasks_changed","session_id":"session-123","tasks":[
          {"task_id":"a0d2815","task_type":"local_agent","description":"Run sleep and echo command"},
          {"task_id":"monitor-1","task_type":"monitor","ambient":true}
        ]}
        """#)

        XCTAssertEqual(events, [
            .backgroundTasks(AgentBackgroundTasksEvent(
                tasks: [
                    AgentBackgroundTask(id: "a0d2815", kind: "local_agent", description: "Run sleep and echo command"),
                    AgentBackgroundTask(id: "monitor-1", kind: "monitor", isAmbient: true)
                ],
                metadata: ["session_id": .string("session-123")]
            ))
        ])
    }

    func testBackgroundTasksChangedWithEmptyListIsAnEmptyEventNotADiagnostic() throws {
        let events = try ClaudeStreamDecoder().decodeLine(#"""
        {"type":"system","subtype":"background_tasks_changed","tasks":[]}
        """#)

        XCTAssertEqual(events, [.backgroundTasks(AgentBackgroundTasksEvent(tasks: []))])
    }

    func testSystemTaskNotificationCarriesTaskIdAndDequeuedDelivery() throws {
        let events = try ClaudeStreamDecoder().decodeLine(#"""
        {"type":"system","subtype":"task_notification","task_id":"a0d2815","tool_use_id":"toolu_agent","status":"completed","summary":"done"}
        """#)

        guard case let .subAgent(subAgent)? = events.first else {
            return XCTFail("Expected a sub-agent event, got \(events)")
        }
        XCTAssertEqual(subAgent.phase, .terminal)
        XCTAssertEqual(subAgent.metadata["task_id"], .string("a0d2815"))
        XCTAssertEqual(subAgent.metadata["delivery"], .string("dequeued"))
    }
}

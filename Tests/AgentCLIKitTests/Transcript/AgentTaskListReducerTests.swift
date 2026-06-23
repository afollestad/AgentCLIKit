import XCTest

@testable import AgentCLIKit

final class AgentTaskListReducerTests: XCTestCase {
    func testReducerBuildsObservedClaudeTaskListSequence() {
        var reducer = AgentTaskListReducer()

        let snapshots = reducer.append(contentsOf: [
            toolCallEnvelope(index: 0, id: "search", name: "ToolSearch", input: [
                "query": .string("select:TaskCreate,TaskUpdate,TaskList,TaskGet")
            ]),
            taskCreateEnvelope(index: 1, id: "create-1", subject: "Read index.html", activeForm: "Reading index.html"),
            taskCreateResultEnvelope(index: 2, id: "create-1", taskId: "1", subject: "Read index.html"),
            taskCreateEnvelope(index: 3, id: "create-2", subject: "Inspect stylesheets", activeForm: "Inspecting stylesheets"),
            taskCreateResultEnvelope(index: 4, id: "create-2", taskId: "2", subject: "Inspect stylesheets"),
            taskCreateEnvelope(index: 5, id: "create-3", subject: "List script files", activeForm: "Listing script files"),
            taskCreateResultEnvelope(index: 6, id: "create-3", taskId: "3", subject: "List script files"),
            taskCreateEnvelope(index: 7, id: "create-4", subject: "Check images directory", activeForm: "Checking images directory"),
            taskCreateResultEnvelope(index: 8, id: "create-4", taskId: "4", subject: "Check images directory"),
            taskUpdateEnvelope(index: 9, id: "update-1a", taskId: "1", status: .inProgress),
            taskUpdateEnvelope(index: 10, id: "update-1b", taskId: "1", status: .completed),
            taskUpdateEnvelope(index: 11, id: "update-2a", taskId: "2", status: .inProgress),
            taskUpdateEnvelope(index: 12, id: "update-2b", taskId: "2", status: .completed),
            taskUpdateEnvelope(index: 13, id: "update-3a", taskId: "3", status: .inProgress),
            taskUpdateEnvelope(index: 14, id: "update-3b", taskId: "3", status: .completed),
            taskUpdateEnvelope(index: 15, id: "update-4a", taskId: "4", status: .inProgress),
            taskUpdateEnvelope(index: 16, id: "update-4b", taskId: "4", status: .completed)
        ])

        XCTAssertEqual(snapshots.count, 16)
        XCTAssertEqual(reducer.snapshot?.id, "tasks-create-1")
        XCTAssertEqual(reducer.snapshot?.items.map(\.id), ["1", "2", "3", "4"])
        XCTAssertEqual(
            reducer.snapshot?.items.map(\.subject),
            ["Read index.html", "Inspect stylesheets", "List script files", "Check images directory"]
        )
        XCTAssertEqual(reducer.snapshot?.items.map(\.status), [.completed, .completed, .completed, .completed])
        XCTAssertEqual(reducer.snapshot?.items[0].activeForm, "Reading index.html")
        XCTAssertEqual(reducer.snapshot?.isComplete, true)
    }

    func testCreateResultResolvesProvisionalTaskIdFromTextFallback() {
        var reducer = AgentTaskListReducer()

        let createSnapshot = reducer.append(taskCreateEnvelope(
            index: 0,
            id: "create-1",
            subject: "Read index.html",
            activeForm: "Reading index.html"
        ))
        let resolvedSnapshot = reducer.append(toolResultEnvelope(
            index: 1,
            id: "create-1",
            content: "Task #1 created successfully: Read index.html"
        ))

        XCTAssertEqual(createSnapshot?.items.map(\.id), ["pending-create-1"])
        XCTAssertEqual(resolvedSnapshot?.items.map(\.id), ["1"])
    }

    func testMalformedTaskToolsDoNotMutateState() {
        var reducer = AgentTaskListReducer()

        let snapshots = reducer.append(contentsOf: [
            toolCallEnvelope(index: 0, id: "missing-subject", name: "TaskCreate", input: ["activeForm": .string("Working")]),
            toolCallEnvelope(index: 1, id: "bad-update", name: "TaskUpdate", input: ["taskId": .string("1"), "status": .string("unknown")]),
            toolResultEnvelope(index: 2, id: "not-pending-create", content: "Task #1 created successfully: Ignored")
        ])

        XCTAssertTrue(snapshots.isEmpty)
        XCTAssertNil(reducer.snapshot)
    }

    func testNewCreateAfterCompletedSnapshotStartsNewTaskList() {
        var reducer = AgentTaskListReducer()

        _ = reducer.append(taskCreateEnvelope(index: 0, id: "create-1", subject: "First"))
        _ = reducer.append(taskCreateResultEnvelope(index: 1, id: "create-1", taskId: "1", subject: "First"))
        _ = reducer.append(taskUpdateEnvelope(index: 2, id: "update-1", taskId: "1", status: .completed))
        let nextSnapshot = reducer.append(taskCreateEnvelope(index: 3, id: "create-2", subject: "Second"))

        XCTAssertEqual(nextSnapshot?.id, "tasks-create-2")
        XCTAssertEqual(nextSnapshot?.items.map(\.subject), ["Second"])
    }

    func testInterruptedTaskCanRestartOnLaterUpdate() {
        var reducer = AgentTaskListReducer()

        _ = reducer.append(taskCreateEnvelope(index: 0, id: "create-1", subject: "Inspect"))
        _ = reducer.append(taskCreateResultEnvelope(index: 1, id: "create-1", taskId: "1", subject: "Inspect"))
        let interruptedSnapshot = reducer.append(taskUpdateEnvelope(index: 2, id: "update-1a", taskId: "1", status: .interrupted))
        let restartedSnapshot = reducer.append(taskUpdateEnvelope(index: 3, id: "update-1b", taskId: "1", status: .inProgress))
        let completedSnapshot = reducer.append(taskUpdateEnvelope(index: 4, id: "update-1c", taskId: "1", status: .completed))

        XCTAssertEqual(interruptedSnapshot?.items.map(\.status), [.interrupted])
        XCTAssertEqual(interruptedSnapshot?.isComplete, false)
        XCTAssertEqual(restartedSnapshot?.items.map(\.status), [.inProgress])
        XCTAssertEqual(completedSnapshot?.items.map(\.status), [.completed])
        XCTAssertEqual(completedSnapshot?.isComplete, true)
    }

    func testTaskEventMetadataReplacesTaskListSnapshot() {
        var reducer = AgentTaskListReducer()
        let snapshot = reducer.append(envelope(
            index: 0,
            event: .task(AgentTaskEvent(
                id: "plan-1",
                phase: .progress,
                metadata: ["todos": .array([
                    .object([
                        "id": .string("todo-1"),
                        "subject": .string("Inspect"),
                        "status": .string("completed")
                    ]),
                    .object([
                        "id": .string("todo-2"),
                        "subject": .string("Implement"),
                        "status": .string("inProgress")
                    ]),
                    .object([
                        "id": .string("todo-3"),
                        "subject": .string("Verify"),
                        "status": .string("cancelled")
                    ])
                ])]
            ))
        ))

        XCTAssertEqual(snapshot?.id, "tasks-plan-1")
        XCTAssertEqual(snapshot?.items.map(\.subject), ["Inspect", "Implement", "Verify"])
        XCTAssertEqual(snapshot?.items.map(\.status), [.completed, .inProgress, .interrupted])
    }

    func testToolResultJSONReplacementParsesInterruptedStatus() {
        var reducer = AgentTaskListReducer()
        let snapshot = reducer.append(toolResultEnvelope(
            index: 0,
            id: "task-list",
            content: """
            {
              "tasks": [
                { "id": "task-1", "subject": "Inspect", "status": "interrupted" },
                { "id": "task-2", "subject": "Patch", "status": "canceled" }
              ]
            }
            """
        ))

        XCTAssertEqual(snapshot?.id, "tasks-task-list")
        XCTAssertEqual(snapshot?.items.map(\.status), [.interrupted, .interrupted])
    }

    func testSessionMetadataDoesNotMutateTaskListSnapshot() {
        var reducer = AgentTaskListReducer()

        let snapshot = reducer.append(envelope(
            index: 0,
            event: .sessionMetadata(AgentSessionMetadataEvent(providerSessionId: "session", name: "Generated Name"))
        ))

        XCTAssertNil(snapshot)
        XCTAssertNil(reducer.snapshot)
    }

    func testRecognizesTaskOnlyToolDiscovery() {
        let taskDiscovery = toolCallEnvelope(index: 0, id: "search", name: "ToolSearch", input: [
            "query": .string("select:TaskCreate,TaskUpdate,TaskList,TaskGet")
        ])
        let mixedDiscovery = toolCallEnvelope(index: 1, id: "mixed", name: "ToolSearch", input: [
            "query": .string("select:TaskCreate,Read")
        ])

        XCTAssertTrue(AgentTaskListReducer.isTaskToolDiscovery(taskDiscovery))
        XCTAssertFalse(AgentTaskListReducer.isTaskToolDiscovery(mixedDiscovery))
    }

    func testCodableCompatibilityDefaults() throws {
        let itemData = Data(#"{"id":"1","subject":"Read index.html","status":"blocked"}"#.utf8)
        let item = try JSONDecoder().decode(AgentTaskListItem.self, from: itemData)
        let interruptedData = Data(#"{"id":"2","subject":"Patch","status":"interrupted"}"#.utf8)
        let interrupted = try JSONDecoder().decode(AgentTaskListItem.self, from: interruptedData)
        let canceledData = Data(#"{"id":"3","subject":"Verify","status":"canceled"}"#.utf8)
        let canceled = try JSONDecoder().decode(AgentTaskListItem.self, from: canceledData)

        XCTAssertEqual(item.status, .pending)
        XCTAssertEqual(interrupted.status, .interrupted)
        XCTAssertEqual(canceled.status, .interrupted)

        let snapshotData = Data(#"{"id":"tasks-1"}"#.utf8)
        let snapshot = try JSONDecoder().decode(AgentTaskListSnapshot.self, from: snapshotData)

        XCTAssertEqual(snapshot.items, [])
    }

    private func taskCreateEnvelope(
        index: Int,
        id: String,
        subject: String,
        activeForm: String? = nil
    ) -> AgentEventEnvelope {
        var input: [String: JSONValue] = [
            "subject": .string(subject),
            "description": .string("Description for \(subject)")
        ]
        if let activeForm {
            input["activeForm"] = .string(activeForm)
        }
        return toolCallEnvelope(index: index, id: id, name: "TaskCreate", input: input)
    }

    private func taskCreateResultEnvelope(
        index: Int,
        id: String,
        taskId: String,
        subject: String
    ) -> AgentEventEnvelope {
        toolResultEnvelope(
            index: index,
            id: id,
            content: "Task #\(taskId) created successfully: \(subject)",
            metadata: [
                "task": .object([
                    "id": .string(taskId),
                    "subject": .string(subject)
                ])
            ]
        )
    }

    private func taskUpdateEnvelope(
        index: Int,
        id: String,
        taskId: String,
        status: AgentTaskListItem.Status
    ) -> AgentEventEnvelope {
        toolCallEnvelope(index: index, id: id, name: "TaskUpdate", input: [
            "taskId": .string(taskId),
            "status": .string(status.rawValue)
        ])
    }

    private func toolCallEnvelope(
        index: Int,
        id: String,
        name: String,
        input: [String: JSONValue]
    ) -> AgentEventEnvelope {
        envelope(
            index: index,
            event: .toolCall(AgentToolCallEvent(
                id: id,
                name: name,
                input: .object(input)
            ))
        )
    }

    private func toolResultEnvelope(
        index: Int,
        id: String,
        content: String,
        metadata: [String: JSONValue] = [:]
    ) -> AgentEventEnvelope {
        envelope(
            index: index,
            event: .toolResult(AgentToolResultEvent(
                id: id,
                isError: false,
                content: content,
                metadata: metadata
            ))
        )
    }

    private func envelope(index: Int, event: AgentEvent) -> AgentEventEnvelope {
        AgentEventEnvelope(
            generation: 1,
            index: index,
            providerId: .claude,
            conversationId: "conversation",
            providerSessionId: nil,
            source: .stdout,
            event: event,
            createdAt: Date(timeIntervalSince1970: TimeInterval(index))
        )
    }
}

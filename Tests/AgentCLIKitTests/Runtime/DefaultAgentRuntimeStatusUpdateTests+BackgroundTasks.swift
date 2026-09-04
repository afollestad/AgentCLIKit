import XCTest

@testable import AgentCLIKit

/// Live background task counting and the provider-initiated turn a dequeued notification starts.
extension DefaultAgentRuntimeStatusUpdateTests {
    func testStatusCountsNonAmbientBackgroundTasksUntilTheirNotificationsArrive() async throws {
        let runtime = DefaultAgentRuntime(adapters: [StatusReportingProviderAdapter(command: echoingShell())])

        try await runtime.spawn(conversationId: "conversation", config: spawnConfig())
        try await runtime.send(.userMessage(AgentMessageInput(text: "tasks:a,b,monitor!")), conversationId: "conversation")
        let announced = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { $0.liveBackgroundTaskCount == 2 }
        XCTAssertEqual(announced?.liveBackgroundTaskCount, 2)

        // Claude shrinks the live set before it delivers the notification; the dropped task stays counted meanwhile.
        try await runtime.send(.userMessage(AgentMessageInput(text: "tasks:b")), conversationId: "conversation")
        let shrunk = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { $0.lastEventIndex >= 2 }
        XCTAssertEqual(shrunk?.liveBackgroundTaskCount, 2)

        try await runtime.send(.userMessage(AgentMessageInput(text: "task-done:a")), conversationId: "conversation")
        let notified = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { $0.liveBackgroundTaskCount == 1 }
        XCTAssertEqual(notified?.liveBackgroundTaskCount, 1)

        try await runtime.send(.userMessage(AgentMessageInput(text: "tasks:")), conversationId: "conversation")
        try await runtime.send(.userMessage(AgentMessageInput(text: "task-done:b")), conversationId: "conversation")
        let drained = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { $0.liveBackgroundTaskCount == 0 }
        XCTAssertEqual(drained?.liveBackgroundTaskCount, 0)

        await runtime.shutdown()
    }

    func testNotificationBeforeLiveSetShrinkDoesNotLeaveTaskAwaiting() async throws {
        let runtime = DefaultAgentRuntime(adapters: [StatusReportingProviderAdapter(command: echoingShell())])

        try await runtime.spawn(conversationId: "conversation", config: spawnConfig())
        try await runtime.send(.userMessage(AgentMessageInput(text: "tasks:a")), conversationId: "conversation")
        try await runtime.send(.userMessage(AgentMessageInput(text: "task-done:a")), conversationId: "conversation")
        try await runtime.send(.userMessage(AgentMessageInput(text: "tasks:")), conversationId: "conversation")
        let status = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { $0.lastEventIndex >= 4 }

        XCTAssertEqual(status?.liveBackgroundTaskCount, 0)

        await runtime.shutdown()
    }

    func testDequeuedNotificationForAnnouncedTaskStartsProviderInitiatedTurn() async throws {
        // No host input is sent: the provider announces a task, reports it done, then answers with a no-op result.
        let runtime = DefaultAgentRuntime(adapters: [
            StatusReportingProviderAdapter(command: providerScript("tasks:a", "task-done:a", "usage:no-op"))
        ])
        let collector = await collectActivities(runtime: runtime)

        try await runtime.spawn(conversationId: "conversation", config: spawnConfig())
        let active = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { $0.isTurnActive }
        XCTAssertTrue(active?.isTurnActive == true)
        let idle = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { !$0.isTurnActive && $0.lastEventIndex >= 3 }
        XCTAssertFalse(idle?.isTurnActive == true)
        XCTAssertTrue(idle?.isProcessRunning == true)

        _ = await waitUntilProcessStops(runtime: runtime, conversationId: "conversation")
        let activities = await collector.value
        XCTAssertEqual(activities.map(\.state), [.active, .idle])
        XCTAssertEqual(Set(activities.map(\.turnId)), ["background-task:a"])
        XCTAssertTrue(activities.allSatisfy { $0.metadata["provider_initiated"] == .bool(true) })

        await runtime.shutdown()
    }

    func testDequeuedNotificationForUnknownTaskDoesNotStartTurn() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            StatusReportingProviderAdapter(command: providerScript("task-done:orphan"))
        ])
        let collector = await collectActivities(runtime: runtime)

        try await runtime.spawn(conversationId: "conversation", config: spawnConfig())
        _ = await waitUntilProcessStops(runtime: runtime, conversationId: "conversation")

        let activities = await collector.value
        XCTAssertEqual(activities, [])

        await runtime.shutdown()
    }

    func testEnqueuedNotificationForAnnouncedTaskDoesNotStartTurn() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            StatusReportingProviderAdapter(command: providerScript("tasks:a", "task-enqueued:a"))
        ])
        let collector = await collectActivities(runtime: runtime)

        try await runtime.spawn(conversationId: "conversation", config: spawnConfig())
        let announced = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { $0.liveBackgroundTaskCount == 1 }
        XCTAssertEqual(announced?.liveBackgroundTaskCount, 1)
        _ = await waitUntilProcessStops(runtime: runtime, conversationId: "conversation")

        let activities = await collector.value
        XCTAssertEqual(activities, [])

        await runtime.shutdown()
    }

    func testTerminalUsageEndsProviderInitiatedTurn() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            StatusReportingProviderAdapter(command: providerScript("tasks:a", "task-done:a", "usage:end_turn"))
        ])

        try await runtime.spawn(conversationId: "conversation", config: spawnConfig())
        let active = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { $0.isTurnActive }
        XCTAssertTrue(active?.isTurnActive == true)
        let status = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { !$0.isTurnActive && $0.lastEventIndex >= 3 }

        XCTAssertFalse(status?.isTurnActive == true)

        await runtime.shutdown()
    }

    func testProcessExitClearsLiveBackgroundTasks() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            StatusReportingProviderAdapter(command: shell("printf 'tasks:a,b\\n'; sleep 0.2"))
        ])

        try await runtime.spawn(conversationId: "conversation", config: spawnConfig())
        let announced = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { $0.liveBackgroundTaskCount == 2 }
        XCTAssertEqual(announced?.liveBackgroundTaskCount, 2)

        let exited = await waitUntilProcessStops(runtime: runtime, conversationId: "conversation")
        XCTAssertEqual(exited?.liveBackgroundTaskCount, 0)

        await runtime.shutdown()
    }

    /// A provider that echoes each stdin line back as a stdout sentinel line for `StatusReportingProviderAdapter`.
    private func echoingShell() -> AgentLaunchConfiguration {
        shell("while IFS= read -r line; do printf '%s\\n' \"$line\"; done")
    }

    /// A provider that emits the given sentinel lines on its own, spaced apart, then exits without any host input.
    private func providerScript(_ lines: String...) -> AgentLaunchConfiguration {
        shell(lines.map { "printf '\($0)\\n'; sleep 0.1" }.joined(separator: "; ") + "; sleep 0.5")
    }

    /// Collects every activity event for `conversation` until the process reports a terminal lifecycle state.
    private func collectActivities(runtime: DefaultAgentRuntime) async -> Task<[AgentActivityEvent], Never> {
        let subscription = await runtime.subscribe(conversationId: "conversation", afterIndex: nil)
        return Task {
            var activities: [AgentActivityEvent] = []
            for await envelope in subscription.events {
                if case let .activity(activity) = envelope.event {
                    activities.append(activity)
                }
                if envelope.event.isTerminalLifecycle {
                    break
                }
            }
            return activities
        }
    }
}

private extension AgentEvent {
    var isTerminalLifecycle: Bool {
        guard case let .lifecycle(lifecycle) = self else {
            return false
        }
        return lifecycle.state.isTerminal
    }
}

import XCTest

@testable import AgentCLIKit

/// Turn-active tracking across cancellation, usage events, and provider-owned activity.
extension DefaultAgentRuntimeStatusUpdateTests {
    func testStatusUpdatesPublishStoppedProcessAfterCancellation() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            StatusReportingProviderAdapter(command: shell("sleep 5"))
        ])
        let stream = await runtime.statusUpdates(conversationId: "conversation")
        let accumulator = StatusAccumulator()
        let collector = Task {
            for await status in stream {
                await accumulator.append(status)
                if status.state == .cancelled && !status.isProcessRunning {
                    break
                }
            }
        }

        try await runtime.spawn(conversationId: "conversation", config: spawnConfig())
        await runtime.cancel(conversationId: "conversation")

        let statuses = await waitForStatusUpdates(accumulator) { statuses in
            statuses.contains { $0.state == .cancelled && !$0.isProcessRunning && $0.processIdentifier == nil }
        }
        collector.cancel()

        XCTAssertTrue(statuses.contains { $0.state == .cancelled && $0.isProcessRunning })
        XCTAssertTrue(statuses.contains { $0.state == .cancelled && !$0.isProcessRunning && $0.processIdentifier == nil })

        await runtime.shutdown()
    }

    func testStatusReportsInitialPromptAsActiveTurn() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            StatusReportingProviderAdapter(command: shell("sleep 1"))
        ])

        try await runtime.spawn(
            conversationId: "conversation",
            config: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: FileManager.default.temporaryDirectory,
                initialPrompt: "Implement the parser"
            )
        )

        let running = await runtime.status(conversationId: "conversation")

        XCTAssertTrue(running?.isTurnActive == true)

        await runtime.shutdown()
    }

    func testStatusKeepsTurnActiveUntilNonToolTerminalUsage() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            StatusReportingProviderAdapter(command: shell("""
            while IFS= read -r line; do
              if [ "$line" = "finish" ]; then
                printf 'usage:end_turn\\n'
              else
                printf 'usage:tool_use\\n'
              fi
            done
            """))
        ])

        try await runtime.spawn(conversationId: "conversation", config: spawnConfig())
        let idle = await runtime.status(conversationId: "conversation")
        XCTAssertFalse(idle?.isTurnActive == true)

        try await runtime.send(.userMessage(AgentMessageInput(text: "start")), conversationId: "conversation")
        let toolUse = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { status in
            status.lastEventIndex >= 2 && status.isTurnActive
        }

        XCTAssertTrue(toolUse?.isTurnActive == true)

        try await runtime.send(.userMessage(AgentMessageInput(text: "finish")), conversationId: "conversation")
        let terminal = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { status in
            status.lastEventIndex >= 3 && !status.isTurnActive
        }

        XCTAssertFalse(terminal?.isTurnActive == true)

        await runtime.shutdown()
    }

    func testStatusKeepsTurnActiveForInterimUsageUpdate() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            StatusReportingProviderAdapter(command: shell("printf 'usage:usage_update\\n'; sleep 1"))
        ])

        try await runtime.spawn(
            conversationId: "conversation",
            config: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: FileManager.default.temporaryDirectory,
                initialPrompt: "Run tools"
            )
        )
        let status = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { status in
            status.lastEventIndex >= 1
        }

        XCTAssertTrue(status?.isTurnActive == true)

        await runtime.shutdown()
    }

    func testTerminalNilStopUsageKeepsTurnInactiveAfterLateInterimUsageUpdate() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            StatusReportingProviderAdapter(command: shell("printf 'usage-terminal:nil\\nusage:usage_update\\n'; sleep 1"))
        ])

        try await runtime.spawn(
            conversationId: "conversation",
            config: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: FileManager.default.temporaryDirectory,
                initialPrompt: "Run tools"
            )
        )
        let status = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { status in
            status.lastEventIndex >= 2
        }

        XCTAssertFalse(status?.isTurnActive == true)
        XCTAssertTrue(status?.isProcessRunning == true)

        await runtime.shutdown()
    }

    func testStatusUsesProviderOwnedActivityEvents() async throws {
        let activitySource = ProviderActivitySource()
        let runtime = DefaultAgentRuntime(adapters: [
            ActivityReportingProviderAdapter(command: shell("sleep 1"), activitySource: activitySource)
        ])

        try await runtime.spawn(conversationId: "conversation", config: spawnConfig())
        await waitForActivitySource(activitySource)
        await activitySource.emit(AgentProviderRuntimeEvent(event: .activity(AgentActivityEvent(state: .active, turnId: "turn-1"))))
        let active = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { status in
            status.isTurnActive
        }

        XCTAssertTrue(active?.isTurnActive == true)

        await activitySource.emit(AgentProviderRuntimeEvent(event: .activity(AgentActivityEvent(state: .idle, turnId: "turn-1"))))
        let idle = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { status in
            !status.isTurnActive && status.lastEventIndex >= 2
        }

        XCTAssertFalse(idle?.isTurnActive == true)

        await runtime.shutdown()
    }

    static func collect(
        _ iterator: inout AsyncStream<AgentRuntimeStatus>.Iterator,
        until isComplete: @escaping @Sendable ([AgentRuntimeStatus]) -> Bool
    ) async -> [AgentRuntimeStatus] {
        var statuses: [AgentRuntimeStatus] = []
        for _ in 0..<20 {
            guard let status = await iterator.next() else {
                break
            }
            statuses.append(status)
            if isComplete(statuses) {
                break
            }
        }
        return statuses
    }

    func waitUntilProcessStops(
        runtime: DefaultAgentRuntime,
        conversationId: AgentConversationID
    ) async -> AgentRuntimeStatus? {
        for _ in 0..<100 {
            let status = await runtime.status(conversationId: conversationId)
            if status?.isProcessRunning == false {
                return status
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await runtime.status(conversationId: conversationId)
    }

    func waitForActivitySource(_ activitySource: ProviderActivitySource) async {
        for _ in 0..<100 {
            if await activitySource.isReady {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func waitUntilStatus(
        runtime: DefaultAgentRuntime,
        conversationId: AgentConversationID,
        matches: (AgentRuntimeStatus) -> Bool
    ) async -> AgentRuntimeStatus? {
        for _ in 0..<100 {
            if let status = await runtime.status(conversationId: conversationId), matches(status) {
                return status
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await runtime.status(conversationId: conversationId)
    }

    func waitForStatusUpdates(
        _ accumulator: StatusAccumulator,
        matches: ([AgentRuntimeStatus]) -> Bool
    ) async -> [AgentRuntimeStatus] {
        for _ in 0..<100 {
            let statuses = await accumulator.statuses
            if matches(statuses) {
                return statuses
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await accumulator.statuses
    }
}

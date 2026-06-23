import XCTest

@testable import AgentCLIKit

final class DefaultAgentRuntimeStatusUpdateTests: XCTestCase {
    func testStatusUpdatesPublishPermissionModeAndWaitingState() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            StatusReportingProviderAdapter(command: shell("printf 'permission:plan\\ncollaboration:plan\\ninteraction:prompt\\n'; sleep 1"))
        ])
        let stream = await runtime.statusUpdates(conversationId: "conversation")
        var iterator = stream.makeAsyncIterator()

        try await runtime.spawn(conversationId: "conversation", config: spawnConfig())

        let statuses = await Self.collect(&iterator, until: { statuses in
            statuses.contains { $0.permissionMode == "plan" && $0.collaborationMode == .plan && $0.waitingState == .prompt }
        })
        XCTAssertTrue(statuses.contains { $0.permissionMode == "plan" })
        XCTAssertTrue(statuses.contains { $0.collaborationMode == .plan })
        XCTAssertTrue(statuses.contains { $0.waitingState == .prompt && $0.inputAvailability == .blocked(reason: "Waiting for a prompt answer.") })
        await runtime.shutdown()
    }

    func testStatusReportsProcessLifecycleFlags() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            StatusReportingProviderAdapter(command: shell("sleep 1"))
        ])

        try await runtime.spawn(conversationId: "conversation", config: spawnConfig())
        let running = await runtime.status(conversationId: "conversation")

        XCTAssertNotNil(running?.processIdentifier)
        XCTAssertTrue(running?.isProcessRunning == true)
        XCTAssertTrue(running?.canCancel == true)

        await runtime.cancel(conversationId: "conversation")
        let cancelled = await waitUntilProcessStops(runtime: runtime, conversationId: "conversation")

        XCTAssertNil(cancelled?.processIdentifier)
        XCTAssertFalse(cancelled?.isProcessRunning == true)
        XCTAssertFalse(cancelled?.canCancel == true)
    }

    func testGoalStatusUpdatesPublishGoalWithoutChangingTurnState() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            StatusReportingProviderAdapter(command: shell("printf 'goal:active:Ship goal mode\\ngoal:achieved:Ship goal mode\\n'; sleep 1"))
        ])
        let stream = await runtime.statusUpdates(conversationId: "conversation")
        var iterator = stream.makeAsyncIterator()

        try await runtime.spawn(conversationId: "conversation", config: spawnConfig())

        let statuses = await Self.collect(&iterator, until: { statuses in
            statuses.contains { $0.goal?.status == .achieved }
        })
        let active = try XCTUnwrap(statuses.first { $0.goal?.status == .active })
        let achieved = try XCTUnwrap(statuses.first { $0.goal?.status == .achieved })

        XCTAssertEqual(active.goal?.objective, "Ship goal mode")
        XCTAssertEqual(active.inputAvailability, .available)
        XCTAssertEqual(active.waitingState, .idle)
        XCTAssertFalse(active.isTurnActive)
        XCTAssertEqual(achieved.goal?.objective, "Ship goal mode")
        XCTAssertEqual(achieved.inputAvailability, .available)
        XCTAssertEqual(achieved.waitingState, .idle)
        XCTAssertFalse(achieved.isTurnActive)

        await runtime.shutdown()
    }

    func testGoalActionWithoutGoalThrowsUnavailable() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            StatusReportingProviderAdapter(command: shell("sleep 1"))
        ])

        try await runtime.spawn(conversationId: "conversation", config: spawnConfig())

        do {
            try await runtime.performGoalAction(.delete, conversationId: "conversation")
            XCTFail("Expected missing active goal to throw.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error.code, .goalUnavailable)
            XCTAssertEqual(error.metadata["provider_id"], .string("claude"))
            XCTAssertEqual(error.metadata["reason"], .string("No active goal is available."))
        }

        await runtime.shutdown()
    }

    func testInitialGoalWithoutInitialPromptDoesNotSeedLocalGoal() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            GoalActionProviderAdapter(command: shell("sleep 1"))
        ])

        try await runtime.spawn(
            conversationId: "conversation",
            config: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: FileManager.default.temporaryDirectory,
                initialGoal: "Ship goal mode"
            )
        )
        let status = await runtime.status(conversationId: "conversation")

        XCTAssertNil(status?.goal)

        await runtime.shutdown()
    }

    func testUnsupportedGoalActionThrowsProviderError() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            StatusReportingProviderAdapter(command: shell("sleep 1"))
        ])

        try await runtime.spawn(
            conversationId: "conversation",
            config: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: FileManager.default.temporaryDirectory,
                initialGoal: "Ship goal mode",
                initialPrompt: "Ship goal mode"
            )
        )

        do {
            try await runtime.performGoalAction(.pause, conversationId: "conversation")
            XCTFail("Expected unsupported provider action to throw.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error.code, .unsupportedCapability)
            XCTAssertEqual(error.metadata["provider_id"], .string("claude"))
            XCTAssertEqual(error.metadata["capability"], .string("goal pause"))
        }

        await runtime.shutdown()
    }

    func testGoalActionUnavailableForCurrentSnapshotThrowsBeforeProvider() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            GoalActionProviderAdapter(command: shell("sleep 1"))
        ])

        try await runtime.spawn(
            conversationId: "conversation",
            config: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: FileManager.default.temporaryDirectory,
                initialGoal: "Ship goal mode",
                initialPrompt: "Ship goal mode"
            )
        )

        do {
            try await runtime.performGoalAction(.pause, conversationId: "conversation")
            XCTFail("Expected unavailable snapshot action to throw.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error.code, .goalUnavailable)
            XCTAssertEqual(error.metadata["provider_id"], .string("claude"))
            XCTAssertEqual(error.metadata["reason"], .string("Goal action 'pause' is unavailable."))
        }

        await runtime.shutdown()
    }

    func testEncodedGoalActionDoesNotMarkTurnActiveAndClearsAfterProviderEvent() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            GoalActionProviderAdapter(command: shell("""
            printf 'goal:active:Ship goal mode\\n'
            while IFS= read -r line; do
              if [ "$line" = "goal-clear" ]; then
                printf 'goal-cleared\\n'
              fi
            done
            """))
        ])

        try await runtime.spawn(conversationId: "conversation", config: spawnConfig())
        let activeGoal = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { status in
            status.lastEventIndex >= 1 && status.goal?.status == .active && !status.isTurnActive
        }
        XCTAssertFalse(activeGoal?.isTurnActive == true)
        try await runtime.performGoalAction(.delete, conversationId: "conversation")

        let status = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { status in
            status.lastEventIndex >= 1 && status.goal == nil
        }

        XCTAssertEqual(status?.inputAvailability, .available)
        XCTAssertEqual(status?.waitingState, .idle)
        XCTAssertFalse(status?.isTurnActive == true)

        await runtime.shutdown()
    }

    func testExistingSessionGoalStartEncodesInputAndMarksTurnActive() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            GoalStartProviderAdapter(command: shell("""
            while IFS= read -r line; do
              if [ "$line" = "goal-start:Ship goal mode" ]; then
                printf 'goal:active:Ship goal mode\\n'
              fi
            done
            """))
        ])

        try await runtime.spawn(conversationId: "conversation", config: spawnConfig())
        try await runtime.startGoal("Ship goal mode", conversationId: "conversation")

        let status = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { status in
            status.goal?.objective == "Ship goal mode" && status.goal?.status == .active
        }

        XCTAssertTrue(status?.isTurnActive == true)
        XCTAssertEqual(status?.inputAvailability, .available)

        await runtime.shutdown()
    }

    func testExistingSessionGoalStartAllowsTerminalSnapshot() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            GoalStartProviderAdapter(command: shell("""
            printf 'goal:achieved:Old goal\\n'
            while IFS= read -r line; do
              if [ "$line" = "goal-start:New goal" ]; then
                printf 'goal:active:New goal\\n'
              fi
            done
            """))
        ])

        try await runtime.spawn(conversationId: "conversation", config: spawnConfig())
        _ = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { status in
            status.goal?.status == .achieved
        }
        try await runtime.startGoal("New goal", conversationId: "conversation")

        let status = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { status in
            status.goal?.objective == "New goal" && status.goal?.status == .active
        }

        XCTAssertEqual(status?.goal?.objective, "New goal")
        XCTAssertTrue(status?.isTurnActive == true)

        await runtime.shutdown()
    }

    func testExistingSessionGoalStartRejectsNonTerminalGoal() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            GoalStartProviderAdapter(command: shell("printf 'goal:active:Ship goal mode\\n'; sleep 1"))
        ])

        try await runtime.spawn(conversationId: "conversation", config: spawnConfig())
        _ = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { status in
            status.goal?.status == .active
        }

        do {
            try await runtime.startGoal("New goal", conversationId: "conversation")
            XCTFail("Expected active goal to block another goal start.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error.code, .goalUnavailable)
            XCTAssertEqual(error.metadata["reason"], .string("A goal is already active."))
        }

        await runtime.shutdown()
    }

    func testExistingSessionGoalStartUnsupportedThrowsProviderError() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            StatusReportingProviderAdapter(command: shell("sleep 1"))
        ])

        try await runtime.spawn(conversationId: "conversation", config: spawnConfig())

        do {
            try await runtime.startGoal("Ship goal mode", conversationId: "conversation")
            XCTFail("Expected unsupported provider goal start to throw.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error.code, .unsupportedCapability)
            XCTAssertEqual(error.metadata["provider_id"], .string("claude"))
            XCTAssertEqual(error.metadata["capability"], .string("existing-session goal start"))
        }

        await runtime.shutdown()
    }

    func testGoalActionUnavailableWhenProviderRemovesActionForActiveTurn() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            GoalActionProviderAdapter(
                command: shell("printf 'goal:active:Ship goal mode\\n'; sleep 1"),
                hideActionsWhileTurnActive: true
            )
        ])

        try await runtime.spawn(conversationId: "conversation", config: spawnConfig())
        _ = await waitUntilStatus(runtime: runtime, conversationId: "conversation") { status in
            status.goal?.status == .active
        }
        try await runtime.send(.userMessage(AgentMessageInput(text: "Continue")), conversationId: "conversation")

        do {
            try await runtime.performGoalAction(.delete, conversationId: "conversation")
            XCTFail("Expected active turn to make goal action unavailable.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error.code, .goalUnavailable)
            XCTAssertEqual(error.metadata["reason"], .string("Goal action 'delete' is unavailable."))
        }

        await runtime.shutdown()
    }

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

    private static func collect(
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

    private func waitUntilProcessStops(
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

    private func waitForActivitySource(_ activitySource: ProviderActivitySource) async {
        for _ in 0..<100 {
            if await activitySource.isReady {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func waitUntilStatus(
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

    private func waitForStatusUpdates(
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

private actor StatusAccumulator {
    private(set) var statuses: [AgentRuntimeStatus] = []

    func append(_ status: AgentRuntimeStatus) {
        statuses.append(status)
    }
}

private actor ProviderActivitySource {
    private var continuation: AsyncStream<AgentProviderRuntimeEvent>.Continuation?
    var isReady: Bool {
        continuation != nil
    }

    func stream() -> AsyncStream<AgentProviderRuntimeEvent> {
        let stream = AsyncStream<AgentProviderRuntimeEvent>.makeStream()
        continuation = stream.continuation
        return stream.stream
    }

    func emit(_ event: AgentProviderRuntimeEvent) {
        continuation?.yield(event)
    }
}

private struct StatusReportingProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(
        id: .claude,
        displayName: "Fake",
        executableNames: ["fake"],
        capabilities: AgentProviderCapabilities(supportsGoalMode: true, supportedGoalActions: [.pause])
    )
    let command: AgentLaunchConfiguration

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        command
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        if line.hasPrefix("permission:") {
            let mode = String(line.dropFirst("permission:".count))
            return [.permissionMode(AgentPermissionModeEvent(mode: mode))]
        }
        if line.hasPrefix("collaboration:") {
            let mode = String(line.dropFirst("collaboration:".count))
            return AgentCollaborationMode(rawValue: mode).map { [.collaborationMode(AgentCollaborationModeEvent(mode: $0))] } ?? []
        }
        if line == "interaction:prompt" {
            return [.interaction(AgentInteractionEvent(id: "prompt", kind: .prompt, prompt: "Continue?"))]
        }
        if line.hasPrefix("goal:") {
            let components = line.split(separator: ":", maxSplits: 2).map(String.init)
            guard components.count == 3, let status = AgentGoalStatus(rawValue: components[1]) else {
                return []
            }
            return [.goal(AgentGoalEvent(snapshot: AgentGoalSnapshot(
                objective: components[2],
                status: status,
                availableActions: status == .active ? [.delete] : []
            )))]
        }
        if line == "goal-cleared" {
            return [.goal(.cleared(objective: "Ship goal mode"))]
        }
        if line == "usage-terminal:nil" {
            return [.usage(AgentUsageEvent(
                model: nil,
                inputTokens: 0,
                outputTokens: 0,
                isTerminal: true
            ))]
        }
        if line.hasPrefix("usage:") {
            let stopReason = String(line.dropFirst("usage:".count))
            return [.usage(AgentUsageEvent(
                model: nil,
                inputTokens: nil,
                outputTokens: nil,
                stopReason: stopReason
            ))]
        }
        return []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        if case let .userMessage(message) = input {
            return Data((message.text + "\n").utf8)
        }
        return Data()
    }
}

private struct GoalActionProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(
        id: .claude,
        displayName: "Fake",
        executableNames: ["fake"],
        capabilities: AgentProviderCapabilities(supportsGoalMode: true, supportedGoalActions: [.delete])
    )
    let command: AgentLaunchConfiguration
    var hideActionsWhileTurnActive = false

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        command
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        if line.hasPrefix("usage:") {
            let stopReason = String(line.dropFirst("usage:".count))
            return [.usage(AgentUsageEvent(
                model: nil,
                inputTokens: nil,
                outputTokens: nil,
                stopReason: stopReason
            ))]
        }
        if line.hasPrefix("goal:") {
            let components = line.split(separator: ":", maxSplits: 2).map(String.init)
            guard components.count == 3, let status = AgentGoalStatus(rawValue: components[1]) else {
                return []
            }
            return [.goal(AgentGoalEvent(snapshot: AgentGoalSnapshot(
                objective: components[2],
                status: status,
                availableActions: status == .active ? [.delete] : []
            )))]
        }
        if line == "goal-cleared" {
            return [.goal(.cleared(objective: "Ship goal mode"))]
        }
        return []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        if case let .userMessage(message) = input {
            return Data((message.text + "\n").utf8)
        }
        return Data()
    }

    func availableGoalActions(for goal: AgentGoalSnapshot, context: AgentProviderGoalActionContext) -> [AgentGoalAction] {
        guard !hideActionsWhileTurnActive || !context.isTurnActive else {
            return []
        }
        return goal.availableActions
    }

    func encodeGoalAction(_ action: AgentGoalAction, context: AgentProviderGoalActionContext) async throws -> Data? {
        guard action == .delete else {
            throw AgentCLIError.unsupportedCapability(providerId: definition.id, capability: "goal \(action.rawValue)")
        }
        return Data("goal-clear\n".utf8)
    }
}

private struct GoalStartProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(
        id: .claude,
        displayName: "Fake",
        executableNames: ["fake"],
        capabilities: AgentProviderCapabilities(
            supportsGoalMode: true,
            supportsExistingSessionGoalStart: true,
            supportedGoalActions: [.delete]
        )
    )
    let command: AgentLaunchConfiguration

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        command
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        if line.hasPrefix("goal:") {
            let components = line.split(separator: ":", maxSplits: 2).map(String.init)
            guard components.count == 3, let status = AgentGoalStatus(rawValue: components[1]) else {
                return []
            }
            return [.goal(AgentGoalEvent(snapshot: AgentGoalSnapshot(
                objective: components[2],
                status: status,
                availableActions: status == .active ? [.delete] : []
            )))]
        }
        return []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        if case let .userMessage(message) = input {
            return Data((message.text + "\n").utf8)
        }
        return Data()
    }

    func encodeGoalStart(_ objective: String, context: AgentProviderGoalStartContext) async throws -> AgentProviderEncodedGoalStart? {
        AgentProviderEncodedGoalStart(data: Data("goal-start:\(objective)\n".utf8), marksTurnActive: true)
    }
}

private struct ActivityReportingProviderAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(id: .claude, displayName: "Fake", executableNames: ["fake"])
    let command: AgentLaunchConfiguration
    let activitySource: ProviderActivitySource

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        command
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }

    func runtimeEvents(context: AgentProviderRuntimeContext) async -> AsyncStream<AgentProviderRuntimeEvent> {
        await activitySource.stream()
    }
}

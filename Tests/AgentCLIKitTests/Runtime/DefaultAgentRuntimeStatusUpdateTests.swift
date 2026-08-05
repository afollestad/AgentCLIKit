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

}

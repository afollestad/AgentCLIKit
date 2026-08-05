import Foundation
import XCTest

@testable import AgentCLIKit

final class CodexProviderAdapterRuntimeTests: XCTestCase {
    func testLegacyTurnInputRequiresRuntimeContext() async throws {
        let adapter = CodexProviderAdapter(configuration: configuration(transport: FakeCodexAppServerTransport(threadIds: ["thread-123"])))

        do {
            _ = try await adapter.encodeInput(.userMessage(AgentMessageInput(text: "Hello")))
            XCTFail("Expected Codex turn input without runtime context to fail.")
        } catch let error as AgentCLIError {
            guard case let .invalidInput(message) = error else {
                XCTFail("Expected invalidInput, got \(error).")
                return
            }
            XCTAssertTrue(message.contains("requires runtime context"))
        }
    }

    func testRuntimeCanSendImmediatelyAfterFreshSpawn() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let runtime = DefaultAgentRuntime(adapters: [adapter])
        let conversationId = AgentConversationID(rawValue: "codex-immediate-send")
        let spawnConfig = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: FileManager.default.temporaryDirectory,
            model: "model-a"
        )

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig)
        try await runtime.send(.userMessage(AgentMessageInput(text: "Start work")), conversationId: conversationId)
        let requestLog = await waitForRequestLog(transport) { log in
            log.map(\.method).contains("turn/start")
        }
        let status = await runtime.status(conversationId: conversationId)
        await runtime.destroy(conversationId: conversationId)

        XCTAssertEqual(status?.providerSessionId, "thread-123")
        XCTAssertEqual(requestLog.map(\.method), ["initialize", "thread/start", "turn/start"])
    }

    func testRuntimeGoalMetadataSetsNativeGoalBeforeFirstTurn() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(
            transport: transport,
            featureSupportChecker: FixedCodexFeatureSupportChecker(supportsFastMode: false, supportsGoalMode: true)
        ))
        let runtime = DefaultAgentRuntime(adapters: [adapter])
        let conversationId = AgentConversationID(rawValue: "codex-goal-metadata-send")
        let spawnConfig = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: FileManager.default.temporaryDirectory,
            model: "model-a"
        )

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        try await runtime.spawn(conversationId: conversationId, config: spawnConfig)
        try await runtime.send(.userMessage(AgentMessageInput(
            text: "Refactor the cache",
            metadata: [
                AgentGoalMetadata.isInitialGoalTransport: .bool(true),
                AgentGoalMetadata.objective: .string("Refactor the cache")
            ]
        )), conversationId: conversationId)
        let requestLog = await waitForRequestLog(transport) { log in
            log.map(\.method).contains("turn/start")
        }
        let events = await Self.collect(subscription.events, limit: 6) { envelopes in
            envelopes.contains { envelope in
                guard case let .goal(goal) = envelope.event,
                      goal.snapshot?.objective == "Refactor the cache",
                      goal.snapshot?.status == .active else {
                    return false
                }
                return true
            }
        }
        await runtime.destroy(conversationId: conversationId)

        XCTAssertEqual(
            requestLog.map(\.method),
            ["initialize", "thread/start", "thread/goal/set", "turn/start"]
        )
        let goalSetParams = try XCTUnwrap(requestLog.first { $0.method == "thread/goal/set" }?.params?.objectValue)
        XCTAssertEqual(goalSetParams["threadId"], .string("thread-123"))
        XCTAssertEqual(goalSetParams["objective"], .string("Refactor the cache"))
        XCTAssertTrue(events.contains {
            guard case let .goal(goal) = $0.event,
                  goal.snapshot?.objective == "Refactor the cache",
                  goal.snapshot?.status == .active else {
                return false
            }
            return true
        })
    }

    func testExistingSessionGoalStartSetsNativeGoalWithoutStartingTurn() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(
            transport: transport,
            featureSupportChecker: FixedCodexFeatureSupportChecker(supportsFastMode: false, supportsGoalMode: true)
        ))
        let runtime = DefaultAgentRuntime(adapters: [adapter])
        let conversationId = AgentConversationID(rawValue: "codex-existing-goal-start")
        let spawnConfig = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: FileManager.default.temporaryDirectory,
            model: "model-a"
        )

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        try await runtime.spawn(conversationId: conversationId, config: spawnConfig)
        try await runtime.startGoal("Refactor the cache", conversationId: conversationId)
        let requestLog = await waitForRequestLog(transport) { log in
            log.map(\.method).contains("thread/goal/set")
        }
        let events = await Self.collect(subscription.events, limit: 6) { envelopes in
            envelopes.contains { envelope in
                guard case let .goal(goal) = envelope.event else {
                    return false
                }
                return goal.snapshot?.objective == "Refactor the cache"
            }
        }
        let status = await runtime.status(conversationId: conversationId)
        await runtime.destroy(conversationId: conversationId)

        XCTAssertEqual(requestLog.map(\.method), ["initialize", "thread/start", "thread/goal/set"])
        let goalSetParams = try XCTUnwrap(requestLog.first { $0.method == "thread/goal/set" }?.params?.objectValue)
        XCTAssertEqual(goalSetParams["threadId"], .string("thread-123"))
        XCTAssertEqual(goalSetParams["objective"], .string("Refactor the cache"))
        XCTAssertTrue(events.contains {
            guard case let .goal(goal) = $0.event else {
                return false
            }
            return goal.snapshot?.objective == "Refactor the cache" && goal.snapshot?.status == .active
        })
        XCTAssertFalse(status?.isTurnActive == true)
    }

    func testStartsTurnAndSteersActiveTurn() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            model: "model-a",
            effort: "medium",
            permissionMode: "on-request"
        )

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        _ = stream
        try await waitForBinding()

        _ = try await adapter.encodeInput(
            .userMessage(AgentMessageInput(text: "Start work")),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: false)
        )
        await transport.emitNotification(method: "thread/status/changed", params: .object([
            "threadId": .string("thread-123"),
            "status": .object(["type": .string("active"), "activeFlags": .array([])])
        ]))
        try await waitForBinding()
        _ = try await adapter.encodeInput(
            .userMessage(AgentMessageInput(text: "Actually use option B")),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: true)
        )

        let requestLog = await transport.requestLog
        let turnStartParams = try XCTUnwrap(requestLog.first { $0.method == "turn/start" }?.params?.objectValue)
        let turnSteerParams = try XCTUnwrap(requestLog.first { $0.method == "turn/steer" }?.params?.objectValue)

        XCTAssertEqual(requestLog.map(\.method), ["initialize", "thread/start", "turn/start", "turn/steer"])
        XCTAssertEqual(turnStartParams["threadId"], .string("thread-123"))
        XCTAssertEqual(turnStartParams["model"], .string("model-a"))
        XCTAssertEqual(turnStartParams["effort"], .string("medium"))
        XCTAssertEqual(turnStartParams["approvalPolicy"], .string("on-request"))
        XCTAssertEqual(turnStartParams["input"], .array([.object([
            "type": .string("text"),
            "text": .string("Start work"),
            "text_elements": .array([])
        ])]))
        XCTAssertEqual(turnSteerParams["threadId"], .string("thread-123"))
        XCTAssertEqual(turnSteerParams["expectedTurnId"], .string("turn-1"))
    }

    func testActiveRuntimeTurnDoesNotSteerBeforeCodexConfirmsActiveTurn() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        _ = stream
        try await waitForBinding()
        _ = try await adapter.encodeInput(
            .userMessage(AgentMessageInput(text: "Start work")),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: false)
        )

        do {
            _ = try await adapter.encodeInput(
                .userMessage(AgentMessageInput(text: "Too early")),
                context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: true)
            )
            XCTFail("Expected premature Codex steering to fail.")
        } catch let error as AgentCLIError {
            guard case let .invalidInput(message) = error else {
                XCTFail("Expected invalidInput, got \(error).")
                return
            }
            XCTAssertEqual(message, "Codex active turn is not ready for steering yet.")
        }

        let requestLog = await transport.requestLog
        XCTAssertEqual(requestLog.map(\.method), ["initialize", "thread/start", "turn/start"])
        XCTAssertEqual(requestLog.filter { $0.method == "turn/steer" }.count, 0)
    }

    func testTurnStartedNotificationEnablesSteering() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        _ = stream
        try await waitForBinding()
        _ = try await adapter.encodeInput(
            .userMessage(AgentMessageInput(text: "Start work")),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: false)
        )
        await transport.emitNotification(method: "turn/started", params: turnNotificationParams(status: "inProgress"))
        try await waitForBinding()
        _ = try await adapter.encodeInput(
            .userMessage(AgentMessageInput(text: "Steer after started")),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: true)
        )

        let requestLog = await transport.requestLog
        let turnSteerParams = try XCTUnwrap(requestLog.first { $0.method == "turn/steer" }?.params?.objectValue)

        XCTAssertEqual(requestLog.map(\.method), ["initialize", "thread/start", "turn/start", "turn/steer"])
        XCTAssertEqual(turnSteerParams["expectedTurnId"], .string("turn-1"))
    }

    func testInterruptUsesActiveTurnId() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        _ = stream
        try await waitForBinding()
        _ = try await adapter.encodeInput(
            .userMessage(AgentMessageInput(text: "Start work")),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: false)
        )
        try await adapter.interrupt(context: interruptContext(threadId: "thread-123", spawnConfig: spawnConfig))

        let requestLog = await transport.requestLog
        let interruptParams = try XCTUnwrap(requestLog.first { $0.method == "turn/interrupt" }?.params?.objectValue)

        XCTAssertEqual(requestLog.map(\.method), ["initialize", "thread/start", "turn/start", "turn/interrupt"])
        XCTAssertEqual(interruptParams["threadId"], .string("thread-123"))
        XCTAssertEqual(interruptParams["turnId"], .string("turn-1"))
    }

    func testIdleStatusClearsActiveTurnForNextMessage() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForBinding()
        async let idleEvents = Self.collect(stream, count: 1)

        _ = try await adapter.encodeInput(
            .userMessage(AgentMessageInput(text: "Start work")),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: false)
        )
        await transport.emitNotification(method: "thread/status/changed", params: .object([
            "threadId": .string("thread-123"),
            "status": .object(["type": .string("idle")])
        ]))
        _ = await idleEvents
        _ = try await adapter.encodeInput(
            .userMessage(AgentMessageInput(text: "Start next turn")),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: false)
        )

        let requestLog = await transport.requestLog

        XCTAssertEqual(requestLog.map(\.method), ["initialize", "thread/start", "turn/start", "turn/start"])
        XCTAssertEqual(requestLog.filter { $0.method == "turn/steer" }.count, 0)
    }

    func testCompletedTurnClearsSteerReadinessForNextMessage() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        _ = stream
        try await waitForBinding()
        _ = try await adapter.encodeInput(
            .userMessage(AgentMessageInput(text: "Start work")),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: false)
        )
        await transport.emitNotification(method: "turn/started", params: turnNotificationParams(status: "inProgress"))
        try await waitForBinding()
        _ = try await adapter.encodeInput(
            .userMessage(AgentMessageInput(text: "Steer current turn")),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: true)
        )
        await transport.emitNotification(method: "turn/completed", params: turnNotificationParams(status: "completed"))
        try await waitForBinding()
        _ = try await adapter.encodeInput(
            .userMessage(AgentMessageInput(text: "Start next turn")),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: false)
        )

        let requestLog = await transport.requestLog

        XCTAssertEqual(requestLog.map(\.method), ["initialize", "thread/start", "turn/start", "turn/steer", "turn/start"])
    }

}

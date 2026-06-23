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

    func testRuntimeEventsReplaceStaleProcessBinding() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-1", "thread-2"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))
        let firstProcessToken = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
        let secondProcessToken = UUID(uuidString: "00000000-0000-0000-0000-000000000002") ?? UUID()

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let firstStream = await adapter.runtimeEvents(context: runtimeContext(
            threadId: "thread-1",
            spawnConfig: spawnConfig,
            processToken: firstProcessToken
        ))
        _ = firstStream
        try await waitForBinding()

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let secondStream = await adapter.runtimeEvents(context: runtimeContext(
            threadId: "thread-2",
            spawnConfig: spawnConfig,
            processToken: secondProcessToken
        ))
        _ = secondStream
        try await waitForBinding()
        _ = try await adapter.encodeInput(
            .userMessage(AgentMessageInput(text: "Start work")),
            context: inputContext(
                threadId: "thread-2",
                spawnConfig: spawnConfig,
                isTurnActive: false,
                processToken: secondProcessToken
            )
        )

        let requestLog = await transport.requestLog
        let turnStartParams = try XCTUnwrap(requestLog.last { $0.method == "turn/start" }?.params?.objectValue)

        XCTAssertEqual(turnStartParams["threadId"], .string("thread-2"))
    }

    func testIncomingPumpRestartsAfterStreamFinishes() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        _ = stream
        _ = await waitForIncomingStreamCount(transport, count: 1)
        try await waitForBinding()
        await transport.finishIncomingMessages()
        try await waitForBinding()
        _ = try await adapter.encodeInput(
            .userMessage(AgentMessageInput(text: "Start work")),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: false)
        )

        let incomingStreamCount = await waitForIncomingStreamCount(transport, count: 2)

        XCTAssertEqual(incomingStreamCount, 2)
    }

    func testRuntimeEventsMapNotificationsAndSettings() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForBinding()
        async let collectedEvents = Self.collect(stream, count: 6)

        await emitRepresentativeNotifications(transport)

        let events = await collectedEvents.map(\.event)
        let settingsMetadata = Self.representativeSettingsMetadata

        XCTAssertTrue(events.contains { $0 == .activity(AgentActivityEvent(
            state: .active,
            metadata: [
                "codex_method": .string("thread/status/changed"),
                "codex_thread_id": .string("thread-123"),
                "codex_status": .string("active")
            ]
        )) })
        XCTAssertTrue(events.contains { event in
            guard case let .activity(activity) = event else {
                return false
            }
            return activity.state == .active && activity.turnId == "turn-1"
        })
        XCTAssertTrue(events.contains { $0 == .permissionMode(AgentPermissionModeEvent(
            mode: "on-request",
            metadata: settingsMetadata
        )) })
        XCTAssertTrue(events.contains { $0 == .collaborationMode(AgentCollaborationModeEvent(
            mode: .plan,
            metadata: settingsMetadata
        )) })
        XCTAssertTrue(events.contains { event in
            guard case let .activity(activity) = event else {
                return false
            }
            return activity.state == .idle && activity.turnId == "turn-1"
        })
    }

    func testRuntimeEventsMapSnakeCaseCompletedPlanItem() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForBinding()
        async let collectedEvents = Self.collect(stream, count: 1)

        await transport.emitNotification(method: "item_completed", params: .object([
            "thread_id": .string("thread-123"),
            "turn_id": .string("turn-1"),
            "completed_at_ms": .number(1_781_657_454_256),
            "item": .object([
                "id": .string("turn-1-plan"),
                "type": .string("Plan"),
                "text": .string(Self.planMarkdown)
            ])
        ]))

        let events = await collectedEvents.map(\.event)

        XCTAssertEqual(events, [
            .message(AgentMessageEvent(
                role: .assistant,
                text: Self.planMarkdown,
                metadata: [
                    AgentPlanProposalMetadata.isProposal: .bool(true),
                    AgentPlanProposalMetadata.proposalId: .string("turn-1-plan"),
                    AgentPlanProposalMetadata.planMarkdown: .string(Self.planMarkdown),
                    "codex_method": .string("item_completed"),
                    "codex_thread_id": .string("thread-123"),
                    "codex_turn_id": .string("turn-1"),
                    "codex_item_id": .string("turn-1-plan"),
                    "codex_item_type": .string("Plan"),
                    "codex_item_phase": .string("completed"),
                    "completed_at_ms": .number(1_781_657_454_256)
                ]
            ))
        ])
    }

    func testRuntimeEventsRecoverCompletedPlanFromCodexSessionTranscript() async throws {
        let codexHome = try temporaryDirectory()
        try writeCodexSessionPlan(codexHome: codexHome, threadId: "thread-123")
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport, codexHomeDirectory: codexHome))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForBinding()
        async let collectedEvents = Self.collect(stream, count: 3)

        await transport.emitNotification(method: "thread/tokenUsage/updated", params: tokenUsageParams())
        await transport.emitNotification(method: "thread/tokenUsage/updated", params: tokenUsageParams())

        let events = await collectedEvents.map(\.event)
        let messages = events.compactMap { event -> AgentMessageEvent? in
            guard case let .message(message) = event else {
                return nil
            }
            return message
        }
        let usageEvents = events.compactMap { event -> AgentUsageEvent? in
            guard case let .usage(usage) = event else {
                return nil
            }
            return usage
        }

        XCTAssertEqual(messages, [
            AgentMessageEvent(
                role: .assistant,
                text: Self.planMarkdown,
                metadata: [
                    AgentPlanProposalMetadata.isProposal: .bool(true),
                    AgentPlanProposalMetadata.proposalId: .string("turn-1-plan"),
                    AgentPlanProposalMetadata.planMarkdown: .string(Self.planMarkdown),
                    "codex_method": .string("item_completed"),
                    "codex_source": .string("session_transcript"),
                    "codex_turn_id": .string("turn-1"),
                    "codex_item_id": .string("turn-1-plan"),
                    "codex_item_type": .string("Plan"),
                    "codex_item_phase": .string("completed"),
                    "completed_at_ms": .number(1_781_660_055_673)
                ]
            )
        ])
        XCTAssertEqual(usageEvents.count, 2)
    }

    func testRuntimeEventsStartInitialPromptTurn() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            initialPrompt: "Implement it"
        )

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        _ = stream
        let requestLog = await waitForRequestLog(transport) { log in
            log.map(\.method).contains("turn/start")
        }
        let turnStartParams = try XCTUnwrap(requestLog.first { $0.method == "turn/start" }?.params?.objectValue)

        XCTAssertEqual(turnStartParams["threadId"], .string("thread-123"))
        XCTAssertEqual(turnStartParams["input"], .array([.object([
            "type": .string("text"),
            "text": .string("Implement it"),
            "text_elements": .array([])
        ])]))
    }

}

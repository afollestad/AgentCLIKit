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

    func configuration(
        transport: FakeCodexAppServerTransport,
        codexHomeDirectory: URL? = nil
    ) -> CodexProviderAdapter.Configuration {
        CodexProviderAdapter.Configuration(
            codexHomeDirectory: codexHomeDirectory,
            requestTimeout: 0.1,
            probeTimeout: 0.1,
            makeTransport: { _ in transport },
            executableResolver: RecordingExecutableResolver(path: nil)
        )
    }

    func runtimeContext(threadId: AgentSessionID, spawnConfig: AgentSpawnConfig) -> AgentProviderRuntimeContext {
        runtimeContext(
            threadId: threadId,
            spawnConfig: spawnConfig,
            processToken: fixedProcessToken
        )
    }

    func runtimeContext(
        threadId: AgentSessionID,
        spawnConfig: AgentSpawnConfig,
        processToken: UUID
    ) -> AgentProviderRuntimeContext {
        AgentProviderRuntimeContext(
            conversationId: "conversation",
            processToken: processToken,
            providerSessionId: threadId,
            spawnConfig: spawnConfig
        )
    }

    private func inputContext(
        threadId: AgentSessionID,
        spawnConfig: AgentSpawnConfig,
        isTurnActive: Bool,
        processToken: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
    ) -> AgentProviderInputContext {
        AgentProviderInputContext(
            conversationId: "conversation",
            processToken: processToken,
            providerSessionId: threadId,
            spawnConfig: spawnConfig,
            isTurnActive: isTurnActive
        )
    }

    private func interruptContext(threadId: AgentSessionID, spawnConfig: AgentSpawnConfig) -> AgentProviderInterruptContext {
        AgentProviderInterruptContext(
            conversationId: "conversation",
            processToken: fixedProcessToken,
            providerSessionId: threadId,
            spawnConfig: spawnConfig
        )
    }

    private var fixedProcessToken: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
    }

    private func turnNotificationParams(status: String) -> JSONValue {
        .object([
            "threadId": .string("thread-123"),
            "turn": .object([
                "id": .string("turn-1"),
                "status": .string(status),
                "items": .array([])
            ])
        ])
    }

    private func emitRepresentativeNotifications(_ transport: FakeCodexAppServerTransport) async {
        await transport.emitNotification(method: "thread/status/changed", params: .object([
            "threadId": .string("thread-123"),
            "status": .object(["type": .string("active"), "activeFlags": .array([])])
        ]))
        await transport.emitNotification(method: "turn/started", params: turnNotificationParams(status: "inProgress"))
        await transport.emitNotification(method: "thread/settings/updated", params: .object([
            "threadId": .string("thread-123"),
            "threadSettings": .object([
                "approvalPolicy": .string("on-request"),
                "model": .string("model-a"),
                "modelProvider": .string("openai"),
                "effort": .string("medium"),
                "collaborationMode": .object(["mode": .string("plan")])
            ])
        ]))
        await transport.emitNotification(method: "turn/completed", params: turnNotificationParams(status: "completed"))
    }

    private static var representativeSettingsMetadata: [String: JSONValue] {
        [
            "codex_method": .string("thread/settings/updated"),
            "codex_thread_id": .string("thread-123"),
            "codex_model": .string("model-a"),
            "codex_model_provider": .string("openai"),
            "codex_effort": .string("medium"),
            "codex_approval_policy": .string("on-request"),
            "codex_collaboration_mode": .object(["mode": .string("plan")])
        ]
    }

    private static let planMarkdown = "# UX Polish Pass\n\n- Tighten the hero.\n- Verify the gallery."

    func waitForBinding() async throws {
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    private func waitForRequestLog(
        _ transport: FakeCodexAppServerTransport,
        matches: ([FakeCodexAppServerTransport.Request]) -> Bool
    ) async -> [FakeCodexAppServerTransport.Request] {
        for _ in 0..<100 {
            let requestLog = await transport.requestLog
            if matches(requestLog) {
                return requestLog
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await transport.requestLog
    }

    private func waitForIncomingStreamCount(_ transport: FakeCodexAppServerTransport, count: Int) async -> Int {
        for _ in 0..<100 {
            let incomingStreamCount = await transport.incomingStreamCount
            if incomingStreamCount >= count {
                return incomingStreamCount
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await transport.incomingStreamCount
    }

    func tokenUsageParams() -> JSONValue {
        .object([
            "threadId": .string("thread-123"),
            "turnId": .string("turn-1"),
            "tokenUsage": .object([
                "total": .object([
                    "inputTokens": .number(10),
                    "outputTokens": .number(5),
                    "cachedInputTokens": .number(3),
                    "totalTokens": .number(15)
                ]),
                "last": .object([
                    "inputTokens": .number(10),
                    "outputTokens": .number(5),
                    "cachedInputTokens": .number(3),
                    "totalTokens": .number(15)
                ]),
                "modelContextWindow": .number(1000)
            ])
        ])
    }

    private func writeCodexSessionPlan(codexHome: URL, threadId: String) throws {
        let sessionsDirectory = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("06", isDirectory: true)
            .appendingPathComponent("16", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let fileURL = sessionsDirectory.appendingPathComponent("rollout-2026-06-16T20-33-05-\(threadId).jsonl")
        let oldPlanLine =
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"thread_id\":\"" + threadId +
            "\",\"turn_id\":\"turn-0\",\"item\":{\"type\":\"Plan\",\"id\":\"turn-0-plan\",\"text\":\"# Old Plan\"}}}"
        let completedPlanLine =
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"item_completed\",\"thread_id\":\"" + threadId +
            "\",\"turn_id\":\"turn-1\",\"item\":{\"type\":\"Plan\",\"id\":\"turn-1-plan\",\"text\":\"" +
            Self.escapedPlanMarkdown + "\"},\"completed_at_ms\":1781660055673}}"
        try [oldPlanLine, completedPlanLine]
            .joined(separator: "\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func collect(_ stream: AsyncStream<AgentProviderRuntimeEvent>, count: Int) async -> [AgentProviderRuntimeEvent] {
        var events: [AgentProviderRuntimeEvent] = []
        for await event in stream {
            events.append(event)
            if events.count >= count {
                break
            }
        }
        return events
    }

    private static let escapedPlanMarkdown = "# UX Polish Pass\\n\\n- Tighten the hero.\\n- Verify the gallery."
}

import XCTest

@testable import AgentCLIKit

/// Runtime event mapping: bindings, pump restarts, notification decoding, and plan recovery.
extension CodexProviderAdapterRuntimeTests {
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
        let requestMethods = await transport.requestMethods

        XCTAssertEqual(incomingStreamCount, 2)
        XCTAssertEqual(requestMethods.filter { $0 == "initialize" }.count, 2)
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

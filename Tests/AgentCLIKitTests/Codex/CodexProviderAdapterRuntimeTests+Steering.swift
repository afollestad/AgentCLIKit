import Foundation
import XCTest

@testable import AgentCLIKit

extension CodexProviderAdapterRuntimeTests {
    func testSteeredTurnPassesClientUserMessageId() async throws {
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
            .userMessage(steeringMessage(text: "Use option B", inputId: "local-message-1")),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: true)
        )

        let requestLog = await transport.requestLog
        let turnSteerParams = try XCTUnwrap(requestLog.first { $0.method == "turn/steer" }?.params?.objectValue)

        XCTAssertEqual(turnSteerParams["clientUserMessageId"], .string("local-message-1"))
    }

    func testSteeringMarkerEmitsOnStartedUserMessageAndSuppressesCompletedDuplicate() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForBinding()
        _ = try await adapter.encodeInput(
            .userMessage(AgentMessageInput(text: "Start work")),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: false)
        )
        await transport.emitNotification(method: "turn/started", params: turnNotificationParams(status: "inProgress"))
        try await waitForBinding()
        _ = try await adapter.encodeInput(
            .userMessage(steeringMessage(text: "Use option B", inputId: "local-message-1")),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: true)
        )

        async let markerEvents = Self.collect(stream, count: 2, timeoutNanoseconds: 100_000_000)
        await transport.emitNotification(
            method: "item/started",
            params: userMessageItemParams(inputId: "local-message-1", itemId: "user-1", status: "inProgress")
        )
        let startedEvents = await markerEvents
        let marker = try XCTUnwrap(startedEvents.first { event in
            guard case let .message(message) = event.event else {
                return false
            }
            return message.metadata[AgentSteeringMetadata.signal] == .string(AgentSteeringMetadata.signalCodexUserMessageStarted)
        })
        guard case let .message(message) = marker.event else {
            XCTFail("Expected steering marker message.")
            return
        }
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.text, "Use option B")
        XCTAssertEqual(message.metadata[AgentSteeringMetadata.inputId], .string("local-message-1"))
        XCTAssertEqual(message.metadata[AgentSteeringMetadata.signal], .string(AgentSteeringMetadata.signalCodexUserMessageStarted))
        XCTAssertEqual(message.metadata["codex_item_phase"], .string("started"))

        async let duplicateEvents = Self.collect(stream, count: 1, timeoutNanoseconds: 100_000_000)
        await transport.emitNotification(
            method: "item/completed",
            params: userMessageItemParams(inputId: "local-message-1", itemId: "user-1", status: "completed")
        )
        let completedEvents = await duplicateEvents
        XCTAssertEqual(completedEvents.count, 0)
    }

    func testSteeringMarkerFallsBackToCompletedUserMessageWhenStartedIsMissing() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForBinding()
        _ = try await adapter.encodeInput(
            .userMessage(AgentMessageInput(text: "Start work")),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: false)
        )
        await transport.emitNotification(method: "turn/started", params: turnNotificationParams(status: "inProgress"))
        try await waitForBinding()
        _ = try await adapter.encodeInput(
            .userMessage(steeringMessage(text: "Use option B", inputId: "local-message-1")),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: true)
        )

        async let events = Self.collect(stream, count: 2, timeoutNanoseconds: 100_000_000)
        await transport.emitNotification(
            method: "item/completed",
            params: userMessageItemParams(inputId: "local-message-1", itemId: "user-1", status: "completed")
        )
        let collectedEvents = await events
        let marker = try XCTUnwrap(collectedEvents.first { event in
            guard case let .message(message) = event.event else {
                return false
            }
            return message.metadata[AgentSteeringMetadata.signal] == .string(AgentSteeringMetadata.signalCodexUserMessageCompleted)
        })
        guard case let .message(message) = marker.event else {
            XCTFail("Expected steering marker message.")
            return
        }
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.text, "Use option B")
        XCTAssertEqual(message.metadata[AgentSteeringMetadata.signal], .string(AgentSteeringMetadata.signalCodexUserMessageCompleted))
        XCTAssertEqual(message.metadata["codex_item_phase"], .string("completed"))
        let userMessages = collectedEvents.compactMap { event -> AgentMessageEvent? in
            guard case let .message(message) = event.event, message.role == .user else {
                return nil
            }
            return message
        }
        XCTAssertEqual(userMessages.count, 1)
    }

    func testFailedSteerRequestClearsPendingSteeringInput() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"], failingMethods: ["turn/steer"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForBinding()
        _ = try await adapter.encodeInput(
            .userMessage(AgentMessageInput(text: "Start work")),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: false)
        )
        await transport.emitNotification(method: "turn/started", params: turnNotificationParams(status: "inProgress"))
        try await waitForBinding()

        do {
            _ = try await adapter.encodeInput(
                .userMessage(steeringMessage(text: "Use option B", inputId: "local-message-1")),
                context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, isTurnActive: true)
            )
            XCTFail("Expected failed steer request.")
        } catch let error as CodexAppServerError {
            guard case .jsonRPCError = error else {
                XCTFail("Expected JSON-RPC failure, got \(error).")
                return
            }
        }

        async let events = Self.collect(stream, count: 3, timeoutNanoseconds: 100_000_000)
        await transport.emitNotification(
            method: "item/completed",
            params: userMessageItemParams(inputId: "local-message-1", itemId: "user-1", status: "completed")
        )
        let collectedEvents = await events
        let steeringSignals = collectedEvents.compactMap { event -> JSONValue? in
            guard case let .message(message) = event.event else {
                return nil
            }
            return message.metadata[AgentSteeringMetadata.signal]
        }
        XCTAssertEqual(steeringSignals, [])
    }

    private func userMessageItemParams(inputId: String, itemId: String, status: String) -> JSONValue {
        .object([
            "threadId": .string("thread-123"),
            "turnId": .string("turn-1"),
            "item": .object([
                "id": .string(itemId),
                "type": .string("userMessage"),
                "clientUserMessageId": .string(inputId),
                "status": .string(status),
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("Use option B")
                    ])
                ])
            ])
        ])
    }

    private func steeringMessage(text: String, inputId: String) -> AgentMessageInput {
        AgentMessageInput(
            text: text,
            metadata: [
                AgentSteeringMetadata.isSteering: .bool(true),
                AgentSteeringMetadata.inputId: .string(inputId)
            ]
        )
    }

    static func collect(
        _ stream: AsyncStream<AgentProviderRuntimeEvent>,
        count: Int,
        timeoutNanoseconds: UInt64
    ) async -> [AgentProviderRuntimeEvent] {
        let accumulator = CodexSteeringRuntimeEventAccumulator()
        let collector = Task {
            for await event in stream {
                let reachedLimit = await accumulator.append(event, limit: count)
                if reachedLimit {
                    break
                }
            }
        }
        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
        collector.cancel()
        return await accumulator.events
    }
}

private actor CodexSteeringRuntimeEventAccumulator {
    private(set) var events: [AgentProviderRuntimeEvent] = []

    func append(_ event: AgentProviderRuntimeEvent, limit: Int) -> Bool {
        events.append(event)
        return events.count >= limit
    }
}

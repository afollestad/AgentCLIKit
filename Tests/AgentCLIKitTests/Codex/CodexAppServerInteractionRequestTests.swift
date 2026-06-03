import Foundation
import XCTest

@testable import AgentCLIKit

final class CodexAppServerInteractionRequestTests: XCTestCase {
    func testCommandApprovalRequestResolvesExplicitAmendmentOnce() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            permissionMode: "on-request"
        )

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForRuntimeBinding(transport)
        async let collectedEvents = Self.collect(stream, count: 1)

        await transport.emitRequest(id: .number(41), method: "item/commandExecution/requestApproval", params: commandApprovalParams())

        let interaction = try Self.interaction(from: await collectedEvents)
        let resolution = AgentInteractionResolution(
            id: interaction.id,
            outcome: .approved,
            metadata: [
                "codex_decision": .object([
                    "acceptWithExecpolicyAmendment": .object([
                        "execpolicy_amendment": .array([.string("git status")])
                    ])
                ])
            ]
        )

        _ = try await adapter.encodeInput(
            .interactionResolution(resolution),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig)
        )
        _ = try await adapter.encodeInput(
            .interactionResolution(resolution),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig)
        )

        let responses = await transport.responseLog

        XCTAssertEqual(interaction.kind, .approval)
        XCTAssertEqual(interaction.prompt, "Bash")
        XCTAssertEqual(interaction.metadata["tool_name"], .string("Bash"))
        XCTAssertEqual(interaction.metadata["tool_input"]?.objectValue?["command"], .string("git status"))
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?.id, .number(41))
        XCTAssertEqual(responses.first?.result, .object([
            "decision": .object([
                "acceptWithExecpolicyAmendment": .object([
                    "execpolicy_amendment": .array([.string("git status")])
                ])
            ])
        ]))
    }

    func testFileChangeApprovalMapsDeclineAndCancel() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForRuntimeBinding(transport)
        async let collectedEvents = Self.collect(stream, count: 2)

        await transport.emitRequest(
            id: .string("file-decline"),
            method: "item/fileChange/requestApproval",
            params: fileChangeApprovalParams("item-file-1")
        )
        await transport.emitRequest(
            id: .string("file-cancel"),
            method: "item/fileChange/requestApproval",
            params: fileChangeApprovalParams("item-file-2")
        )

        let interactions = try Self.interactions(from: await collectedEvents)
        _ = try await adapter.encodeInput(
            .interactionResolution(AgentInteractionResolution(id: interactions[0].id, outcome: .denied)),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig)
        )
        _ = try await adapter.encodeInput(
            .interactionResolution(AgentInteractionResolution(id: interactions[1].id, outcome: .cancelled)),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig)
        )

        let responses = await transport.responseLog

        XCTAssertEqual(interactions.map(\.prompt), ["FileChange", "FileChange"])
        XCTAssertEqual(responses.map(\.result), [
            .object(["decision": .string("decline")]),
            .object(["decision": .string("cancel")])
        ])
    }

    func testPermissionProfileApprovalGrantsAndDenialUsesErrorFallback() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForRuntimeBinding(transport)
        async let collectedEvents = Self.collect(stream, count: 2)

        await transport.emitRequest(
            id: .string("perm-grant"),
            method: "item/permissions/requestApproval",
            params: permissionApprovalParams("item-perm-1")
        )
        await transport.emitRequest(
            id: .string("perm-deny"),
            method: "item/permissions/requestApproval",
            params: permissionApprovalParams("item-perm-2")
        )

        let interactions = try Self.interactions(from: await collectedEvents)
        _ = try await adapter.encodeInput(
            .interactionResolution(AgentApprovalSelection(
                interactionId: interactions[0].id,
                providerId: .codex,
                outcome: .approved,
                grantKind: .session,
                operation: "Permissions"
            ).resolution()),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig)
        )
        _ = try await adapter.encodeInput(
            .interactionResolution(AgentInteractionResolution(id: interactions[1].id, outcome: .denied)),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig)
        )

        let responses = await transport.responseLog
        let errors = await transport.errorResponseLog

        XCTAssertEqual(interactions.first?.metadata["codex_denial_fallback"], .string("jsonRPCError"))
        XCTAssertEqual(responses.first?.id, .string("perm-grant"))
        XCTAssertEqual(responses.first?.result?.objectValue?["scope"], .string("session"))
        XCTAssertEqual(responses.first?.result?.objectValue?["permissions"], permissionGrant())
        XCTAssertEqual(errors.first?.id, .string("perm-deny"))
        XCTAssertEqual(errors.first?.code, -32000)
        XCTAssertTrue(errors.first?.message.contains("denied") == true)
    }

    func testMcpElicitationPromptAcceptsContent() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForRuntimeBinding(transport)
        async let collectedEvents = Self.collect(stream, count: 1)

        await transport.emitRequest(id: .number(51), method: "mcpServer/elicitation/request", params: mcpElicitationParams())

        let interaction = try Self.interaction(from: await collectedEvents)
        _ = try await adapter.encodeInput(
            .interactionResolution(AgentInteractionResolution(
                id: interaction.id,
                outcome: .answered,
                metadata: ["content": .object(["choice": .string("yes")])]
            )),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig)
        )

        let response = await transport.responseLog.first

        XCTAssertEqual(interaction.kind, .prompt)
        XCTAssertEqual(interaction.prompt, "Pick one")
        XCTAssertEqual(response?.result, .object([
            "action": .string("accept"),
            "content": .object(["choice": .string("yes")])
        ]))
    }

    func testToolRequestUserInputPromptReturnsAnswers() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForRuntimeBinding(transport)
        async let collectedEvents = Self.collect(stream, count: 1)

        await transport.emitRequest(id: .string("input-1"), method: "item/tool/requestUserInput", params: toolRequestUserInputParams())

        let interaction = try Self.interaction(from: await collectedEvents)
        _ = try await adapter.encodeInput(
            .interactionResolution(AgentInteractionResolution(id: interaction.id, outcome: .answered, responseText: "Option A")),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig)
        )

        let response = await transport.responseLog.first

        XCTAssertEqual(interaction.kind, .prompt)
        XCTAssertEqual(interaction.prompt, "Which option?")
        XCTAssertEqual(interaction.promptOptions, [
            AgentPromptOption(
                id: "0",
                label: "Option A",
                description: "Use A",
                responseText: "Option A",
                metadata: ["label": .string("Option A"), "description": .string("Use A")]
            )
        ])
        XCTAssertEqual(response?.result, .object([
            "answers": .object([
                "choice": .object(["answers": .array([.string("Option A")])])
            ])
        ]))
    }

    func testUnsupportedDynamicToolCallRespondsAndEmitsDiagnostic() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForRuntimeBinding(transport)
        async let collectedEvents = Self.collect(stream, count: 1)

        await transport.emitRequest(id: .number(61), method: "item/tool/call", params: dynamicToolCallParams())

        let events = await collectedEvents
        let event = try XCTUnwrap(events.first?.event)
        let responses = await waitForResponseCount(transport, count: 1)

        XCTAssertEqual(responses.first?.id, .number(61))
        XCTAssertEqual(responses.first?.result?.objectValue?["success"], .bool(false))
        guard case let .diagnostic(diagnostic) = event else {
            XCTFail("Expected diagnostic, got \(event).")
            return
        }
        XCTAssertEqual(diagnostic.severity, .warning)
        XCTAssertEqual(diagnostic.metadata["codex_tool_name"], .string("customTool"))
    }

    func testReplacingRuntimeBindingDropsPendingRequestFromOldProcess() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))
        let oldProcessToken = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
        let newProcessToken = UUID(uuidString: "00000000-0000-0000-0000-000000000002") ?? UUID()

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let oldStream = await adapter.runtimeEvents(context: runtimeContext(
            threadId: "thread-123",
            spawnConfig: spawnConfig,
            processToken: oldProcessToken
        ))
        try await waitForRuntimeBinding(transport)
        async let collectedEvents = Self.collect(oldStream, count: 1)
        await transport.emitRequest(id: .number(71), method: "item/commandExecution/requestApproval", params: commandApprovalParams())
        let interaction = try Self.interaction(from: await collectedEvents)

        let newStream = await adapter.runtimeEvents(context: runtimeContext(
            threadId: "thread-123",
            spawnConfig: spawnConfig,
            processToken: newProcessToken
        ))
        _ = newStream
        try await waitForRuntimeBinding(transport)

        _ = try await adapter.encodeInput(
            .interactionResolution(AgentInteractionResolution(id: interaction.id, outcome: .approved)),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig, processToken: oldProcessToken)
        )

        let responses = await transport.responseLog

        XCTAssertTrue(responses.isEmpty)
    }

    func testCompletedTurnDropsPendingApproval() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: runtimeContext(threadId: "thread-123", spawnConfig: spawnConfig))
        try await waitForRuntimeBinding(transport)
        async let collectedEvents = Self.collect(stream, count: 1)

        await transport.emitRequest(id: .number(81), method: "item/commandExecution/requestApproval", params: commandApprovalParams())
        let interaction = try Self.interaction(from: await collectedEvents)
        async let completedEvents = Self.collect(stream, count: 1)
        await transport.emitNotification(method: "turn/completed", params: turnCompletedParams())
        _ = await completedEvents

        _ = try await adapter.encodeInput(
            .interactionResolution(AgentInteractionResolution(id: interaction.id, outcome: .approved)),
            context: inputContext(threadId: "thread-123", spawnConfig: spawnConfig)
        )

        let responses = await transport.responseLog

        XCTAssertTrue(responses.isEmpty)
    }
}

private extension CodexAppServerInteractionRequestTests {
    private func configuration(transport: FakeCodexAppServerTransport) -> CodexProviderAdapter.Configuration {
        CodexProviderAdapter.Configuration(
            requestTimeout: 0.1,
            probeTimeout: 0.1,
            makeTransport: { _ in transport }
        )
    }

    private func runtimeContext(
        threadId: AgentSessionID,
        spawnConfig: AgentSpawnConfig,
        processToken: UUID? = nil
    ) -> AgentProviderRuntimeContext {
        AgentProviderRuntimeContext(
            conversationId: "conversation",
            processToken: processToken ?? Self.processToken,
            providerSessionId: threadId,
            spawnConfig: spawnConfig
        )
    }

    private func inputContext(
        threadId: AgentSessionID,
        spawnConfig: AgentSpawnConfig,
        processToken: UUID? = nil
    ) -> AgentProviderInputContext {
        AgentProviderInputContext(
            conversationId: "conversation",
            processToken: processToken ?? Self.processToken,
            providerSessionId: threadId,
            spawnConfig: spawnConfig,
            isTurnActive: true
        )
    }

    private func waitForRuntimeBinding(_ transport: FakeCodexAppServerTransport) async throws {
        for _ in 0..<100 {
            if await transport.incomingStreamCount > 0 {
                try await Task.sleep(nanoseconds: 20_000_000)
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    private func waitForResponseCount(
        _ transport: FakeCodexAppServerTransport,
        count: Int
    ) async -> [FakeCodexAppServerTransport.Response] {
        for _ in 0..<100 {
            let responses = await transport.responseLog
            if responses.count >= count {
                return responses
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await transport.responseLog
    }

    private func commandApprovalParams() -> JSONValue {
        .object([
            "threadId": .string("thread-123"),
            "turnId": .string("turn-1"),
            "itemId": .string("item-command"),
            "startedAtMs": .number(1_000),
            "command": .string("git status"),
            "cwd": .string("/tmp/project"),
            "reason": .string("Inspect repository state"),
            "proposedExecpolicyAmendment": .array([.string("git status")])
        ])
    }

    private func turnCompletedParams() -> JSONValue {
        .object([
            "threadId": .string("thread-123"),
            "turn": .object([
                "id": .string("turn-1"),
                "status": .string("completed")
            ])
        ])
    }

    private func fileChangeApprovalParams(_ itemId: String) -> JSONValue {
        .object([
            "threadId": .string("thread-123"),
            "turnId": .string("turn-1"),
            "itemId": .string(itemId),
            "startedAtMs": .number(1_000),
            "reason": .string("Apply generated changes"),
            "grantRoot": .string("/tmp/project")
        ])
    }

    private func permissionApprovalParams(_ itemId: String) -> JSONValue {
        .object([
            "threadId": .string("thread-123"),
            "turnId": .string("turn-1"),
            "itemId": .string(itemId),
            "startedAtMs": .number(1_000),
            "cwd": .string("/tmp/project"),
            "reason": .string("Need network access"),
            "permissions": permissionGrant()
        ])
    }

    private func mcpElicitationParams() -> JSONValue {
        .object([
            "threadId": .string("thread-123"),
            "turnId": .string("turn-1"),
            "serverName": .string("demo-mcp"),
            "mode": .string("form"),
            "message": .string("Pick one"),
            "requestedSchema": .object([
                "type": .string("object"),
                "properties": .object([:])
            ])
        ])
    }

    private func toolRequestUserInputParams() -> JSONValue {
        .object([
            "threadId": .string("thread-123"),
            "turnId": .string("turn-1"),
            "itemId": .string("item-input"),
            "questions": .array([.object([
                "id": .string("choice"),
                "header": .string("Choice"),
                "question": .string("Which option?"),
                "options": .array([.object([
                    "label": .string("Option A"),
                    "description": .string("Use A")
                ])])
            ])])
        ])
    }

    private func dynamicToolCallParams() -> JSONValue {
        .object([
            "threadId": .string("thread-123"),
            "turnId": .string("turn-1"),
            "callId": .string("call-1"),
            "tool": .string("customTool"),
            "arguments": .object(["value": .string("test")])
        ])
    }

    private func permissionGrant() -> JSONValue {
        .object(["network": .object(["enabled": .bool(true)])])
    }

    private static var processToken: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
    }

    private static func collect(_ stream: AsyncStream<AgentProviderRuntimeEvent>, count: Int) async -> [AgentProviderRuntimeEvent] {
        var events: [AgentProviderRuntimeEvent] = []
        for await event in stream {
            events.append(event)
            if events.count >= count {
                break
            }
        }
        return events
    }

    private static func interaction(from events: [AgentProviderRuntimeEvent]) throws -> AgentInteractionEvent {
        try XCTUnwrap(interactions(from: events).first)
    }

    private static func interactions(from events: [AgentProviderRuntimeEvent]) throws -> [AgentInteractionEvent] {
        let interactions = events.compactMap { event -> AgentInteractionEvent? in
            guard case let .interaction(interaction) = event.event else {
                return nil
            }
            return interaction
        }
        XCTAssertEqual(interactions.count, events.count)
        return interactions
    }
}

import Foundation
import XCTest

@testable import AgentCLIKit

extension CodexAppServerInteractionRequestTests {
    func testCommandApprovalIncludesApprovalIdentityToolInput() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: approvalIdentityConfiguration(transport: transport))
        let spawnConfig = approvalIdentitySpawnConfig()

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: approvalIdentityRuntimeContext(spawnConfig: spawnConfig))
        try await waitForApprovalIdentityRuntimeBinding(transport)
        async let collectedEvents = Self.collectApprovalIdentityEvents(stream, count: 1)

        await transport.emitRequest(
            id: .number(41),
            method: "item/commandExecution/requestApproval",
            params: approvalIdentityCommandParams(command: #"/bin/zsh -lc 'git status'"#)
        )

        let interaction = try Self.approvalIdentityInteraction(from: await collectedEvents)

        XCTAssertEqual(interaction.metadata["approval_identity_tool_input"], .object(["command": .string("git status")]))
    }

    func testCommandApprovalAutoResolvesFromHostSessionApprovalStore() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let approvalStore = InMemoryAgentApprovalPolicyStore()
        _ = await approvalStore.recordSessionApproval(AgentSessionApprovalGrant(
            providerId: .codex,
            conversationId: "conversation",
            sessionId: "thread-123",
            matchKind: .bashCommandGroup,
            matchValue: "git add"
        ))
        let adapter = CodexProviderAdapter(configuration: approvalIdentityConfiguration(
            transport: transport,
            sessionApprovalPolicyStore: approvalStore
        ))
        let spawnConfig = approvalIdentitySpawnConfig()

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: approvalIdentityRuntimeContext(spawnConfig: spawnConfig))
        _ = stream
        try await waitForApprovalIdentityRuntimeBinding(transport)

        await transport.emitRequest(
            id: .number(42),
            method: "item/commandExecution/requestApproval",
            params: approvalIdentityCommandParams(command: #"/bin/zsh -lc 'git add README.md'"#)
        )
        let responses = await waitForApprovalIdentityResponseCount(transport, count: 1)

        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?.id, .number(42))
        XCTAssertEqual(responses.first?.result, .object(["decision": .string("accept")]))
    }

    func testScopedCommandSessionApprovalResolvesCurrentRequestOnce() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: approvalIdentityConfiguration(transport: transport))
        let spawnConfig = approvalIdentitySpawnConfig()

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: approvalIdentityRuntimeContext(spawnConfig: spawnConfig))
        try await waitForApprovalIdentityRuntimeBinding(transport)
        async let collectedEvents = Self.collectApprovalIdentityEvents(stream, count: 1)

        await transport.emitRequest(id: .number(43), method: "item/commandExecution/requestApproval", params: approvalIdentityCommandParams())

        let interaction = try Self.approvalIdentityInteraction(from: await collectedEvents)
        _ = try await adapter.encodeInput(
            .interactionResolution(AgentInteractionResolution(
                id: interaction.id,
                outcome: .approved,
                metadata: [
                    "approval_grant_kind": .string("session"),
                    "approval_session_scope": .string("group")
                ]
            )),
            context: approvalIdentityInputContext(spawnConfig: spawnConfig)
        )

        let responses = await transport.responseLog

        XCTAssertEqual(responses.first?.result, .object(["decision": .string("accept")]))
    }
}

private extension CodexAppServerInteractionRequestTests {
    static let approvalIdentityProcessToken = UUID()

    func approvalIdentityConfiguration(
        transport: FakeCodexAppServerTransport,
        sessionApprovalPolicyStore: any AgentSessionApprovalPolicyStore = InMemoryAgentApprovalPolicyStore()
    ) -> CodexProviderAdapter.Configuration {
        CodexProviderAdapter.Configuration(
            requestTimeout: 0.1,
            probeTimeout: 0.1,
            sessionApprovalPolicyStore: sessionApprovalPolicyStore,
            makeTransport: { _ in transport },
            executableResolver: RecordingExecutableResolver(path: nil)
        )
    }

    func approvalIdentitySpawnConfig() -> AgentSpawnConfig {
        AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            permissionMode: "on-request"
        )
    }

    func approvalIdentityRuntimeContext(spawnConfig: AgentSpawnConfig) -> AgentProviderRuntimeContext {
        AgentProviderRuntimeContext(
            conversationId: "conversation",
            processToken: Self.approvalIdentityProcessToken,
            providerSessionId: "thread-123",
            spawnConfig: spawnConfig
        )
    }

    func approvalIdentityInputContext(spawnConfig: AgentSpawnConfig) -> AgentProviderInputContext {
        AgentProviderInputContext(
            conversationId: "conversation",
            processToken: Self.approvalIdentityProcessToken,
            providerSessionId: "thread-123",
            spawnConfig: spawnConfig,
            isTurnActive: true
        )
    }

    func waitForApprovalIdentityRuntimeBinding(_ transport: FakeCodexAppServerTransport) async throws {
        for _ in 0..<100 {
            if await transport.incomingStreamCount > 0 {
                try await Task.sleep(nanoseconds: 20_000_000)
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    func waitForApprovalIdentityResponseCount(
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

    func approvalIdentityCommandParams(command: String = "git status") -> JSONValue {
        .object([
            "threadId": .string("thread-123"),
            "turnId": .string("turn-1"),
            "itemId": .string("item-command"),
            "startedAtMs": .number(1_000),
            "command": .string(command),
            "cwd": .string("/tmp/project"),
            "reason": .string("Inspect repository state"),
            "proposedExecpolicyAmendment": .array([.string("git status")])
        ])
    }

    static func collectApprovalIdentityEvents(
        _ stream: AsyncStream<AgentProviderRuntimeEvent>,
        count: Int
    ) async -> [AgentProviderRuntimeEvent] {
        var events: [AgentProviderRuntimeEvent] = []
        for await event in stream {
            events.append(event)
            if events.count >= count {
                break
            }
        }
        return events
    }

    static func approvalIdentityInteraction(from events: [AgentProviderRuntimeEvent]) throws -> AgentInteractionEvent {
        try XCTUnwrap(events.compactMap { runtimeEvent in
            if case let .interaction(interaction) = runtimeEvent.event {
                return interaction
            }
            return nil
        }.first)
    }
}

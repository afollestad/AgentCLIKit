import XCTest

@testable import AgentCLIKit

final class DefaultAgentRuntimeSessionTests: XCTestCase {
    func testRuntimePersistsProviderSessionDiscoveredFromEvents() async throws {
        let sessionStore = InMemoryAgentSessionStore()
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let runtime = DefaultAgentRuntime(
            adapters: [SessionReportingProviderAdapter(command: shell("printf 'session:provider-session\\n'"))],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig(workingDirectory: workingDirectory))
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, providerId: .claude)

        XCTAssertEqual(status?.providerSessionId, "provider-session")
        XCTAssertEqual(persisted?.providerSessionId, "provider-session")
        XCTAssertEqual(persisted?.workingDirectory?.path, AgentPathHelpers.canonicalPath(workingDirectory))
        XCTAssertEqual(persisted?.generation, status?.generation)
    }

    func testRuntimePersistsProviderSessionNameDiscoveredFromMetadataEvents() async throws {
        let sessionStore = InMemoryAgentSessionStore()
        let runtime = DefaultAgentRuntime(
            adapters: [SessionReportingProviderAdapter(command: shell("printf 'metadata:provider-session:Generated Name\\n'"))],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, providerId: .claude)

        XCTAssertEqual(status?.providerSessionId, "provider-session")
        XCTAssertEqual(status?.providerSessionName, "Generated Name")
        XCTAssertEqual(persisted?.providerSessionId, "provider-session")
        XCTAssertEqual(persisted?.providerSessionName, "Generated Name")
        XCTAssertEqual(persisted?.metadata, ["source": .string("runtime")])
    }

    func testRuntimeDoesNotClearProviderSessionNameFromNilMetadata() async throws {
        let sessionStore = InMemoryAgentSessionStore()
        let runtime = DefaultAgentRuntime(
            adapters: [SessionReportingProviderAdapter(command: shell("""
            printf 'metadata:provider-session:Generated Name\\n'
            printf 'metadata:provider-session:\\n'
            printf 'metadata:provider-session:   \\n'
            """))],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, providerId: .claude)

        XCTAssertEqual(status?.providerSessionName, "Generated Name")
        XCTAssertEqual(persisted?.providerSessionName, "Generated Name")
    }

    func testRuntimeDoesNotCarryProviderSessionNameAcrossSessionChangeWithoutName() async throws {
        let sessionStore = InMemoryAgentSessionStore()
        let runtime = DefaultAgentRuntime(
            adapters: [SessionReportingProviderAdapter(command: shell("printf 'metadata:first-session:Old Name\\nmetadata:second-session:\\n'"))],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, providerId: .claude)

        XCTAssertEqual(status?.providerSessionId, "second-session")
        XCTAssertNil(status?.providerSessionName)
        XCTAssertEqual(persisted?.providerSessionId, "second-session")
        XCTAssertNil(persisted?.providerSessionName)
    }

    func testRuntimeSeedsProviderSessionNameFromResumedRecord() async throws {
        let conversationId: AgentConversationID = "conversation"
        let sessionStore = InMemoryAgentSessionStore(records: [
            AgentSessionRecord(
                conversationId: conversationId,
                providerId: .claude,
                providerSessionId: "provider-session",
                providerSessionName: "Saved Name",
                generation: 1
            )
        ])
        let runtime = DefaultAgentRuntime(
            adapters: [SequencedProviderAdapter(launchSequence: LaunchSequence([
                shell("printf 'message:ready\\n'")
            ]))],
            sessionStore: sessionStore
        )

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, providerId: .claude)

        XCTAssertEqual(status?.providerSessionId, "provider-session")
        XCTAssertEqual(status?.providerSessionName, "Saved Name")
        XCTAssertEqual(persisted?.providerSessionName, "Saved Name")
    }

    func testRuntimePersistsLaunchSeededProviderSessionOnFirstEvent() async throws {
        let sessionStore = InMemoryAgentSessionStore()
        let runtime = DefaultAgentRuntime(
            adapters: [SequencedProviderAdapter(launchSequence: LaunchSequence([
                AgentLaunchConfiguration(
                    executable: "/bin/sh",
                    arguments: ["-c", "printf 'message:ready\\n'"],
                    providerSessionId: "seeded-session"
                )
            ]))],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, providerId: .claude)

        XCTAssertEqual(status?.providerSessionId, "seeded-session")
        XCTAssertEqual(persisted?.providerSessionId, "seeded-session")
        XCTAssertEqual(persisted?.metadata, ["source": .string("runtime")])
    }

    func testReconfigureIgnoresSessionEventAfterSlowPersistence() async throws {
        let sessionStore = SlowSessionStore(saveDelay: 200_000_000)
        let launchSequence = LaunchSequence([
            shell("printf 'session:old-session\\n'"),
            shell("printf 'message:new\\n'")
        ])
        let runtime = DefaultAgentRuntime(
            adapters: [SequencedSessionReportingProviderAdapter(launchSequence: launchSequence)],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        try await Task.sleep(nanoseconds: 20_000_000)
        try await runtime.reconfigure(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        try await Task.sleep(nanoseconds: 250_000_000)
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let events = await Self.collect(subscription.events, limit: (status?.lastEventIndex ?? -1) + 1)

        XCTAssertFalse(events.contains { $0.event == .diagnostic(AgentDiagnosticEvent(severity: .info, message: "session")) })
        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "new")) })
    }

    func testReconfigureIgnoresSessionPersistenceFailureFromReplacedProcess() async throws {
        let sessionStore = FailingSlowSessionStore(saveDelay: 200_000_000)
        let launchSequence = LaunchSequence([
            shell("printf 'session:old-session\\n'"),
            shell("printf 'message:new\\n'")
        ])
        let runtime = DefaultAgentRuntime(
            adapters: [SequencedSessionReportingProviderAdapter(launchSequence: launchSequence)],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        try await Task.sleep(nanoseconds: 20_000_000)
        try await runtime.reconfigure(conversationId: conversationId, config: spawnConfig())
        _ = await waitForExit(runtime: runtime, conversationId: conversationId)
        try await Task.sleep(nanoseconds: 250_000_000)
        let status = await runtime.status(conversationId: conversationId)
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let events = await Self.collect(subscription.events, limit: (status?.lastEventIndex ?? -1) + 1)

        let diagnostics = events.compactMap { envelope -> AgentDiagnosticEvent? in
            guard case let .diagnostic(diagnostic) = envelope.event else {
                return nil
            }
            return diagnostic
        }
        XCTAssertFalse(diagnostics.contains { $0.message.contains("Could not persist provider session") })
        XCTAssertFalse(diagnostics.contains { $0.code == .sessionStoreSaveFailed })
        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "new")) })
    }

    func testReconfigurePreservesCurrentProviderSessionWhenOlderSaveFinishesLast() async throws {
        let sessionStore = OutOfOrderSessionStore(delays: [
            "old-session": 250_000_000,
            "new-session": 20_000_000
        ])
        let launchSequence = LaunchSequence([
            shell("printf 'session:old-session\\n'"),
            shell("printf 'session:new-session\\n'")
        ])
        let runtime = DefaultAgentRuntime(
            adapters: [SequencedSessionReportingProviderAdapter(launchSequence: launchSequence)],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        try await Task.sleep(nanoseconds: 20_000_000)
        try await runtime.reconfigure(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        try await Task.sleep(nanoseconds: 350_000_000)
        let persisted = try await sessionStore.record(conversationId: conversationId, providerId: .claude)

        XCTAssertEqual(status?.providerSessionId, "new-session")
        XCTAssertEqual(persisted?.providerSessionId, "new-session")
    }

    func testRuntimePreservesCurrentProviderSessionNameWhenOlderSaveFinishesLast() async throws {
        let sessionStore = OutOfOrderSessionStore(delays: [
            "Old Name": 250_000_000,
            "New Name": 20_000_000
        ])
        let launchSequence = LaunchSequence([
            shell("printf 'metadata:same-session:Old Name\\n'"),
            shell("printf 'metadata:same-session:New Name\\n'")
        ])
        let runtime = DefaultAgentRuntime(
            adapters: [SequencedSessionReportingProviderAdapter(launchSequence: launchSequence)],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        try await Task.sleep(nanoseconds: 20_000_000)
        try await runtime.reconfigure(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        try await Task.sleep(nanoseconds: 350_000_000)
        let persisted = try await sessionStore.record(conversationId: conversationId, providerId: .claude)

        XCTAssertEqual(status?.providerSessionId, "same-session")
        XCTAssertEqual(status?.providerSessionName, "New Name")
        XCTAssertEqual(persisted?.providerSessionId, "same-session")
        XCTAssertEqual(persisted?.providerSessionName, "New Name")
    }

    func testRuntimeIgnoresStaleProviderSessionNamePersistenceFailureAfterNewNameSucceeds() async throws {
        let sessionStore = SelectiveFailureOutOfOrderSessionStore(
            delays: [
                "Old Name": 250_000_000,
                "New Name": 20_000_000
            ],
            failingKeys: ["Old Name"]
        )
        let launchSequence = LaunchSequence([
            shell("printf 'metadata:same-session:Old Name\\n'"),
            shell("printf 'metadata:same-session:New Name\\n'")
        ])
        let runtime = DefaultAgentRuntime(
            adapters: [SequencedSessionReportingProviderAdapter(launchSequence: launchSequence)],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        try await Task.sleep(nanoseconds: 20_000_000)
        try await runtime.reconfigure(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        try await Task.sleep(nanoseconds: 350_000_000)
        let persisted = try await sessionStore.record(conversationId: conversationId, providerId: .claude)
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let events = await Self.collect(subscription.events, limit: (status?.lastEventIndex ?? -1) + 1)
        let diagnostics = events.compactMap { envelope -> AgentDiagnosticEvent? in
            guard case let .diagnostic(diagnostic) = envelope.event else {
                return nil
            }
            return diagnostic
        }

        XCTAssertEqual(status?.providerSessionId, "same-session")
        XCTAssertEqual(status?.providerSessionName, "New Name")
        XCTAssertEqual(persisted?.providerSessionId, "same-session")
        XCTAssertEqual(persisted?.providerSessionName, "New Name")
        XCTAssertFalse(diagnostics.contains { $0.code == .sessionStoreSaveFailed })
    }
}

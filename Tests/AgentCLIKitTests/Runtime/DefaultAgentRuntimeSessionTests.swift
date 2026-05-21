import XCTest

@testable import AgentCLIKit

final class DefaultAgentRuntimeSessionTests: XCTestCase {
    func testRuntimePersistsProviderSessionDiscoveredFromEvents() async throws {
        let sessionStore = InMemoryAgentSessionStore()
        let runtime = DefaultAgentRuntime(
            adapters: [SessionReportingProviderAdapter(command: shell("printf 'session:provider-session\\n'"))],
            sessionStore: sessionStore
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, providerId: "fake")

        XCTAssertEqual(status?.providerSessionId, "provider-session")
        XCTAssertEqual(persisted?.providerSessionId, "provider-session")
        XCTAssertEqual(persisted?.generation, status?.generation)
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
        let persisted = try await sessionStore.record(conversationId: conversationId, providerId: "fake")

        XCTAssertEqual(status?.providerSessionId, "new-session")
        XCTAssertEqual(persisted?.providerSessionId, "new-session")
    }
}

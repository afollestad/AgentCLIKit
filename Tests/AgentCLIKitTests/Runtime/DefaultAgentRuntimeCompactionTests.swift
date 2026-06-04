import XCTest

@testable import AgentCLIKit

final class DefaultAgentRuntimeCompactionTests: XCTestCase {
    func testContextCompactionTerminalSynthesizesStartAndDeduplicatesPhases() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("printf 'compact:completed\\ncompact:completed\\n'"))
        ])
        let conversationId: AgentConversationID = "conversation"
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { envelope in
                envelope.event == .lifecycle(AgentLifecycleEvent(state: .exited, exitCode: 0))
            }
        })
        let compactions = events.compactMap { envelope -> AgentContextCompactionEvent? in
            guard case let .contextCompaction(compaction) = envelope.event else {
                return nil
            }
            return compaction
        }

        XCTAssertEqual(compactions.map(\.phase), [.started, .completed])
        XCTAssertEqual(compactions.map(\.id), ["compact-1", "compact-1"])
        XCTAssertEqual(compactions.first?.metadata["synthetic"], .bool(true))
    }

    func testProviderRuntimeContextCompactionEventsDeduplicatePhases() async throws {
        let source = ContextCompactionRuntimeSource()
        let runtime = DefaultAgentRuntime(adapters: [
            ContextCompactionRuntimeAdapter(command: shell("sleep 1"), source: source)
        ])
        let conversationId: AgentConversationID = "conversation"
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        await waitForRuntimeSource(source)
        await source.emit(AgentProviderRuntimeEvent(
            event: .contextCompaction(AgentContextCompactionEvent(id: "compact-1", phase: .started)),
            source: .hook
        ))
        await source.emit(AgentProviderRuntimeEvent(
            event: .contextCompaction(AgentContextCompactionEvent(id: "compact-1", phase: .started)),
            source: .hook
        ))
        await source.emit(AgentProviderRuntimeEvent(
            event: .contextCompaction(AgentContextCompactionEvent(id: "compact-1", phase: .completed)),
            source: .hook
        ))
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { envelope in
                envelope.event == .contextCompaction(AgentContextCompactionEvent(id: "compact-1", phase: .completed))
            }
        })
        let compactionEnvelopes = events.filter { envelope in
            if case .contextCompaction = envelope.event {
                return true
            }
            return false
        }

        XCTAssertEqual(compactionEnvelopes.map(\.source), [.hook, .hook])
        XCTAssertEqual(compactionEnvelopes.map(\.event), [
            .contextCompaction(AgentContextCompactionEvent(id: "compact-1", phase: .started)),
            .contextCompaction(AgentContextCompactionEvent(id: "compact-1", phase: .completed))
        ])

        await runtime.shutdown()
    }

    func testCancelSynthesizesFailedTerminalForOpenContextCompaction() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("printf 'compact:started\\n'; sleep 5"))
        ])
        let conversationId: AgentConversationID = "conversation"
        let startSubscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        _ = await Self.collect(startSubscription.events, until: { envelopes in
            envelopes.compactionEvents.contains { $0.phase == .started }
        })
        await runtime.cancel(conversationId: conversationId)

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains {
                $0.event == .lifecycle(AgentLifecycleEvent(state: .cancelled, message: "Cancelled by host."))
            }
        })
        let compactions = events.compactionEvents

        XCTAssertEqual(compactions.map(\.phase), [.started, .failed])
        XCTAssertEqual(compactions.map(\.id), ["compact-1", "compact-1"])
        XCTAssertEqual(compactions.last?.errorMessage, "Context compaction was interrupted by host cancellation.")
        XCTAssertEqual(compactions.last?.metadata["synthetic"], .bool(true))
        XCTAssertEqual(compactions.last?.metadata["terminal_reason"], .string("cancelled"))

        await runtime.shutdown()
    }

    func testContextCompactionStartAfterTerminalLifecycleSynthesizesFailedTerminal() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("sleep 5"))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        await runtime.cancel(conversationId: conversationId)

        let events = await runtime.contextCompactionGuardedEvents(
            from: .contextCompaction(AgentContextCompactionEvent(id: "compact-1", phase: .started)),
            conversationId: conversationId
        )
        let compactions = events.compactionEvents

        XCTAssertEqual(compactions.map(\.phase), [.started, .failed])
        XCTAssertEqual(compactions.last?.errorMessage, "Context compaction was interrupted by host cancellation.")
        XCTAssertEqual(compactions.last?.metadata["synthetic"], .bool(true))
        XCTAssertEqual(compactions.last?.metadata["terminal_reason"], .string("cancelled"))
        await runtime.shutdown()
    }

    func testProviderRuntimeContextCompactionIgnoresTerminalAfterTerminal() async throws {
        let source = ContextCompactionRuntimeSource()
        let runtime = DefaultAgentRuntime(adapters: [
            ContextCompactionRuntimeAdapter(command: shell("sleep 5"), source: source)
        ])
        let conversationId: AgentConversationID = "conversation"
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        await waitForRuntimeSource(source)
        await source.emit(AgentProviderRuntimeEvent(
            event: .contextCompaction(AgentContextCompactionEvent(id: "compact-1", phase: .started)),
            source: .hook
        ))
        await source.emit(AgentProviderRuntimeEvent(
            event: .contextCompaction(AgentContextCompactionEvent(id: "compact-1", phase: .failed)),
            source: .hook
        ))
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains {
                $0.event == .contextCompaction(AgentContextCompactionEvent(id: "compact-1", phase: .failed))
            }
        })
        XCTAssertEqual(events.compactionEvents.map(\.phase), [.started, .failed])

        await source.emit(AgentProviderRuntimeEvent(
            event: .contextCompaction(AgentContextCompactionEvent(id: "compact-1", phase: .completed)),
            source: .hook
        ))
        try await Task.sleep(nanoseconds: 50_000_000)
        let replay = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let replayedEvents = await Self.collect(replay.events)

        XCTAssertEqual(replayedEvents.compactionEvents.map(\.phase), [.started, .failed])
        await runtime.shutdown()
    }

    func testProcessExitSynthesizesFailedTerminalForOpenContextCompaction() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("printf 'compact:started\\n'"))
        ])
        let conversationId: AgentConversationID = "conversation"
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { envelope in
                envelope.event == .lifecycle(AgentLifecycleEvent(state: .exited, exitCode: 0))
            }
        })
        let compactions = events.compactionEvents

        XCTAssertEqual(compactions.map(\.phase), [.started, .failed])
        XCTAssertEqual(compactions.last?.errorMessage, "Context compaction did not finish before the provider process ended.")
        XCTAssertEqual(compactions.last?.metadata["synthetic"], .bool(true))
        XCTAssertEqual(compactions.last?.metadata["terminal_reason"], .string("exited"))
    }

    private func waitForRuntimeSource(_ source: ContextCompactionRuntimeSource) async {
        for _ in 0..<100 {
            if await source.isReady {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private actor ContextCompactionRuntimeSource {
    private var continuation: AsyncStream<AgentProviderRuntimeEvent>.Continuation?
    var isReady: Bool {
        continuation != nil
    }

    func stream() -> AsyncStream<AgentProviderRuntimeEvent> {
        let stream = AsyncStream<AgentProviderRuntimeEvent>.makeStream()
        continuation = stream.continuation
        return stream.stream
    }

    func emit(_ event: AgentProviderRuntimeEvent) {
        continuation?.yield(event)
    }
}

private struct ContextCompactionRuntimeAdapter: AgentProviderAdapter {
    let definition = AgentProviderDefinition(id: .claude, displayName: "Fake", executableNames: ["fake"])
    let command: AgentLaunchConfiguration
    let source: ContextCompactionRuntimeSource

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        command
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }

    func runtimeEvents(context: AgentProviderRuntimeContext) async -> AsyncStream<AgentProviderRuntimeEvent> {
        await source.stream()
    }
}

private extension [AgentEventEnvelope] {
    var compactionEvents: [AgentContextCompactionEvent] {
        compactMap { envelope -> AgentContextCompactionEvent? in
            guard case let .contextCompaction(compaction) = envelope.event else {
                return nil
            }
            return compaction
        }
    }
}

private extension [AgentEvent] {
    var compactionEvents: [AgentContextCompactionEvent] {
        compactMap { event -> AgentContextCompactionEvent? in
            guard case let .contextCompaction(compaction) = event else {
                return nil
            }
            return compaction
        }
    }
}

import XCTest

@testable import AgentCLIKit

final class DefaultAgentRuntimeTests: XCTestCase {
    func testSubscribeAfterIndexReplaysOnlyLaterEvents() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("printf 'message:first\\nmessage:second\\n'"))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        _ = await waitForExit(runtime: runtime, conversationId: conversationId)

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: 2)
        let replayed = await Self.collect(subscription.events, limit: 2)

        XCTAssertFalse(replayed.contains { $0.index <= 2 })
    }

    func testMarkPersistedCompactsOldReplayBuffer() async throws {
        let runtime = DefaultAgentRuntime(
            adapters: [FakeProviderAdapter(command: shell("printf 'message:one\\nmessage:two\\nmessage:three\\n'"))],
            replayLimit: 2
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let lastEventIndex = try XCTUnwrap(status?.lastEventIndex)
        await runtime.markPersisted(conversationId: conversationId, generation: status?.generation ?? 1, upTo: lastEventIndex)

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let replayed = await Self.collect(subscription.events, limit: 2)

        XCTAssertEqual(replayed.map(\.index), [lastEventIndex - 1, lastEventIndex])
    }

    func testReplayBufferKeepsUnpersistedEventsBeyondReplayLimit() async throws {
        let runtime = DefaultAgentRuntime(
            adapters: [FakeProviderAdapter(command: shell("printf 'message:first\\nmessage:second\\n'"))],
            replayLimit: 1
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let expectedCount = try XCTUnwrap(status?.lastEventIndex) + 1

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let replayed = await Self.collect(subscription.events, limit: expectedCount)

        XCTAssertEqual(replayed.count, expectedCount)
    }

    func testMarkPersistedClampsFutureCursorToKnownEvents() async throws {
        let runtime = DefaultAgentRuntime(
            adapters: [FakeProviderAdapter(command: shell("printf 'message:first\\nmessage:second\\n'"))],
            replayLimit: 1
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let lastEventIndex = try XCTUnwrap(status?.lastEventIndex)
        await runtime.markPersisted(
            conversationId: conversationId,
            generation: status?.generation ?? 1,
            upTo: lastEventIndex + 100
        )

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let replayed = await Self.collect(subscription.events, limit: 2)

        XCTAssertEqual(replayed.map(\.index), [lastEventIndex])
    }

    func testMalformedStdoutIncludesRecentStderrTail() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("printf 'tail detail\\n' >&2; sleep 0.05; printf 'malformed\\n'"))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { envelope in
                guard case let .diagnostic(diagnostic) = envelope.event else {
                    return false
                }
                return diagnostic.severity == .error
            }
        })

        let diagnostics = events.compactMap { envelope -> AgentDiagnosticEvent? in
            guard case let .diagnostic(diagnostic) = envelope.event else {
                return nil
            }
            return diagnostic
        }
        XCTAssertTrue(diagnostics.contains { $0.message.contains("Malformed fake stdout.") })
        XCTAssertTrue(diagnostics.contains { $0.message.contains("tail detail") })
        XCTAssertTrue(diagnostics.contains { $0.code == .providerDecodeFailed })
        XCTAssertTrue(diagnostics.contains { $0.metadata["stderr_tail"] == .string("tail detail") })
        XCTAssertTrue(diagnostics.contains { $0.metadata["raw_stdout_line"] == .string("malformed") })
    }

    func testSendSerializesInputToProviderStdin() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("read first; read second; printf \"message:$first\\nmessage:$second\\n\""))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        try await runtime.send(.userMessage(AgentMessageInput(text: "hello")), conversationId: conversationId)
        try await runtime.send(.userMessage(AgentMessageInput(text: "again")), conversationId: conversationId)
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "again")) }
        })

        let messages = events.compactMap { envelope -> String? in
            guard case let .message(message) = envelope.event else {
                return nil
            }
            return message.text
        }
        XCTAssertEqual(messages, ["hello", "again"])
    }

    func testSendUserMessageFailsWhileInteractionIsPending() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("printf 'interaction:prompt\\n'; sleep 1"))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        _ = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { $0.event == .interaction(AgentInteractionEvent(id: "prompt", kind: .prompt, prompt: "Continue?")) }
        })

        do {
            try await runtime.send(.userMessage(AgentMessageInput(text: "hello")), conversationId: conversationId)
            XCTFail("Expected blocked input to throw.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(
                error,
                .invalidInput("Input is blocked for conversation 'conversation': Waiting for a prompt answer.")
            )
        }
        await runtime.shutdown()
    }

    func testResolveInteractionSendsResolutionOnceAndUnblocksInput() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("""
            printf 'interaction:prompt\\n'
            read resolution
            read message
            printf "message:$resolution,$message\\n"
            """))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        _ = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { $0.event == .interaction(AgentInteractionEvent(id: "prompt", kind: .prompt, prompt: "Continue?")) }
        })

        let resolution = AgentInteractionResolution(id: "prompt", outcome: .answered, responseText: "yes")
        try await runtime.resolveInteraction(resolution, conversationId: conversationId)
        try await runtime.resolveInteraction(resolution, conversationId: conversationId)
        try await runtime.send(.userMessage(AgentMessageInput(text: "next")), conversationId: conversationId)
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "yes,next")) }
        })

        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "yes,next")) })
    }

    func testConcurrentSendsPreserveCallOrderThroughAsyncEncoding() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            DelayedEncodingProviderAdapter(command: shell("read first; read second; printf \"message:$first,$second\\n\""))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        async let firstSend: Void = runtime.send(.userMessage(AgentMessageInput(text: "first")), conversationId: conversationId)
        try await Task.sleep(nanoseconds: 20_000_000)
        async let secondSend: Void = runtime.send(.userMessage(AgentMessageInput(text: "second")), conversationId: conversationId)
        _ = try await (firstSend, secondSend)
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "first,second")) }
        })

        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "first,second")) })
    }

    func testSubscribeBeforeSpawnReceivesFutureEvents() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("printf 'message:future\\n'"))
        ])
        let conversationId: AgentConversationID = "conversation"

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "future")) }
        })

        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "future")) })
    }

    func testRuntimeFlushesFinalStdoutLineWithoutTrailingNewline() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("printf 'message:final'"))
        ])
        let conversationId: AgentConversationID = "conversation"

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "final")) }
        })

        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "final")) })
    }

    func testSubscribeBeforeSpawnReturnsUsableGenerationForPersistence() async throws {
        let runtime = DefaultAgentRuntime(
            adapters: [FakeProviderAdapter(command: shell("printf 'message:first\\nmessage:second\\n'"))],
            replayLimit: 1
        )
        let conversationId: AgentConversationID = "conversation"

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { $0.event == .lifecycle(AgentLifecycleEvent(state: .exited, exitCode: 0)) }
        })
        await runtime.markPersisted(
            conversationId: conversationId,
            generation: subscription.generation,
            upTo: events.last?.index ?? -1
        )

        let replay = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let replayed = await Self.collect(replay.events, limit: 1)

        XCTAssertEqual(subscription.generation, 1)
        XCTAssertEqual(replayed.map(\.index), [events.last?.index ?? -1])
    }

    func testReconfigureIgnoresOutputFromReplacedProcess() async throws {
        let launchSequence = LaunchSequence([
            shell("trap '' TERM; sleep 0.2; printf 'message:old\\n'"),
            shell("printf 'message:new\\n'")
        ])
        let runtime = DefaultAgentRuntime(adapters: [
            SequencedProviderAdapter(launchSequence: launchSequence)
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        try await runtime.reconfigure(conversationId: conversationId, config: spawnConfig())
        try await Task.sleep(nanoseconds: 400_000_000)

        let status = await runtime.status(conversationId: conversationId)
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let events = await Self.collect(subscription.events, limit: (status?.lastEventIndex ?? -1) + 1)

        let messages = events.compactMap { envelope -> String? in
            guard case let .message(message) = envelope.event else {
                return nil
            }
            return message.text
        }
        XCTAssertEqual(messages, ["new"])
    }

    func testReconfigureIgnoresOutputDecodedAfterProcessReplacement() async throws {
        let launchSequence = LaunchSequence([
            shell("printf 'message:old\\n'"),
            shell("printf 'message:new\\n'")
        ])
        let runtime = DefaultAgentRuntime(adapters: [
            DelayedDecodingProviderAdapter(launchSequence: launchSequence)
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        try await Task.sleep(nanoseconds: 20_000_000)
        try await runtime.reconfigure(conversationId: conversationId, config: spawnConfig())
        _ = await waitForExit(runtime: runtime, conversationId: conversationId)
        try await Task.sleep(nanoseconds: 250_000_000)
        let status = await runtime.status(conversationId: conversationId)
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let events = await Self.collect(subscription.events, limit: (status?.lastEventIndex ?? -1) + 1)

        let messages = events.compactMap { envelope -> String? in
            guard case let .message(message) = envelope.event else {
                return nil
            }
            return message.text
        }
        XCTAssertEqual(messages, ["new"])
    }

    func testFailedReconfigureKeepsExistingProcessRunning() async throws {
        let launchSequence = FailableLaunchSequence([
            .launch(shell("sleep 5")),
            .fail("rejected")
        ])
        let runtime = DefaultAgentRuntime(adapters: [
            FailableLaunchProviderAdapter(launchSequence: launchSequence)
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        do {
            try await runtime.reconfigure(conversationId: conversationId, config: spawnConfig())
            XCTFail("Expected reconfigure to fail.")
        } catch {
            try await Task.sleep(nanoseconds: 100_000_000)
            let status = await runtime.status(conversationId: conversationId)
            XCTAssertEqual(status?.state, .running)
        }

        await runtime.kill(conversationId: conversationId)
    }

    func testFailedReplacementLaunchKeepsExistingProcessRunning() async throws {
        let launchSequence = LaunchSequence([
            shell("sleep 5"),
            AgentLaunchConfiguration(executable: "/no/such/executable")
        ])
        let runtime = DefaultAgentRuntime(adapters: [
            SequencedProviderAdapter(launchSequence: launchSequence)
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        do {
            try await runtime.reconfigure(conversationId: conversationId, config: spawnConfig())
            XCTFail("Expected replacement launch to fail.")
        } catch {
            try await Task.sleep(nanoseconds: 100_000_000)
            let status = await runtime.status(conversationId: conversationId)
            XCTAssertEqual(status?.state, .running)
        }

        await runtime.kill(conversationId: conversationId)
    }

    func testReconfigurePreservesEventsEmittedDuringReplacementSetup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let replacementStartedPath = directory.appendingPathComponent("replacement-started").path
        let oldMessageEmittedPath = directory.appendingPathComponent("old-message-emitted").path
        let launchSequence = FailableLaunchSequence([
            .launch(shell("""
            while [ ! -f '\(replacementStartedPath)' ]; do sleep 0.005; done
            printf 'message:old-before-replace\\n'
            touch '\(oldMessageEmittedPath)'
            sleep 5
            """)),
            .triggerAndWait(
                triggerPath: replacementStartedPath,
                observedPath: oldMessageEmittedPath,
                shell("printf 'message:new\\n'")
            )
        ])
        let runtime = DefaultAgentRuntime(adapters: [
            FailableLaunchProviderAdapter(launchSequence: launchSequence)
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        try await runtime.reconfigure(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let replayed = await Self.collect(subscription.events, limit: (status?.lastEventIndex ?? -1) + 1)
        let messages = replayed.compactMap { envelope -> String? in
            guard case let .message(message) = envelope.event else {
                return nil
            }
            return message.text
        }

        XCTAssertTrue(messages.contains("old-before-replace"))
        XCTAssertTrue(messages.contains("new"))
    }

    func testFreshSessionIncrementsGeneration() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("printf 'message:fresh\\n'"))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        _ = await waitForExit(runtime: runtime, conversationId: conversationId)
        try await runtime.freshSession(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)

        XCTAssertEqual(status?.generation, 2)
    }

    func testFreshSessionEventsUseEnvelopeGenerationForPersistence() async throws {
        let launchSequence = LaunchSequence([
            shell("printf 'message:first\\n'"),
            shell("printf 'message:fresh-one\\nmessage:fresh-two\\n'")
        ])
        let runtime = DefaultAgentRuntime(
            adapters: [SequencedProviderAdapter(launchSequence: launchSequence)],
            replayLimit: 1
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        _ = await waitForExit(runtime: runtime, conversationId: conversationId)
        try await runtime.freshSession(conversationId: conversationId, config: spawnConfig())
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "fresh-two")) }
        })
        let freshEnvelope = events.first { $0.event == .message(AgentMessageEvent(role: .assistant, text: "fresh-two")) }
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let lastEventIndex = try XCTUnwrap(status?.lastEventIndex)
        let freshGeneration = try XCTUnwrap(freshEnvelope?.generation)

        await runtime.markPersisted(
            conversationId: conversationId,
            generation: freshGeneration,
            upTo: lastEventIndex
        )
        let replay = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let replayed = await Self.collect(replay.events, limit: 2)

        XCTAssertEqual(subscription.generation, 1)
        XCTAssertEqual(freshGeneration, 2)
        XCTAssertEqual(replayed.map(\.index), [lastEventIndex])
    }

    func testReplayLimitIsClampedToAtLeastOne() async throws {
        let runtime = DefaultAgentRuntime(
            adapters: [FakeProviderAdapter(command: shell("printf 'message:first\\nmessage:second\\n'"))],
            replayLimit: 0
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let lastEventIndex = try XCTUnwrap(status?.lastEventIndex)
        await runtime.markPersisted(conversationId: conversationId, generation: status?.generation ?? 1, upTo: lastEventIndex)

        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let replayed = await Self.collect(subscription.events, limit: 2)

        XCTAssertEqual(replayed.map(\.index), [lastEventIndex])
    }

    func testReconfigureKeepsGenerationAndReplacesProcess() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("printf 'message:configured\\n'"))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        _ = await waitForExit(runtime: runtime, conversationId: conversationId)
        try await runtime.reconfigure(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)

        XCTAssertEqual(status?.generation, 1)
    }

}

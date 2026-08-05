import XCTest

@testable import AgentCLIKit

/// Reconfiguration and fresh-session behavior around process replacement.
extension DefaultAgentRuntimeTests {
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
        // Gate the first process's decode open across the replacement instead of using a fixed decode
        // delay; on slow runners a delay let the old decode finish while its token was still current,
        // legitimately appending "old" and flaking the assertion.
        let decodeGate = DecodeGate()
        let runtime = DefaultAgentRuntime(adapters: [
            GatedDecodingProviderAdapter(launchSequence: launchSequence, gate: decodeGate, gatedLine: "message:old")
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        await decodeGate.waitUntilEntered()
        try await runtime.reconfigure(conversationId: conversationId, config: spawnConfig())
        await decodeGate.release()
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

import Darwin
import XCTest

@testable import AgentCLIKit

final class DefaultAgentRuntimeLifecycleTests: XCTestCase {
    func testLifecycleStdoutReplayAndStatus() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("printf 'message:first\\n'"))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { $0.event == .lifecycle(AgentLifecycleEvent(state: .exited, exitCode: 0)) }
        })

        XCTAssertEqual(subscription.generation, 1)
        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "first")) })

        let status = await runtime.status(conversationId: conversationId)
        XCTAssertEqual(status?.state, .exited)
        XCTAssertEqual(status?.lastEventIndex, events.last?.index)
    }

    func testLifecycleReplayIncludesStartingAndRunningEvents() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("printf 'message:first\\n'"))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let replayed = await Self.collect(subscription.events, limit: (status?.lastEventIndex ?? -1) + 1)
        let lifecycleStates = replayed.compactMap { envelope -> AgentLifecycleState? in
            guard case let .lifecycle(lifecycle) = envelope.event else {
                return nil
            }
            return lifecycle.state
        }

        XCTAssertEqual(lifecycleStates.prefix(2), [.starting, .running])
    }

    func testLaunchFailureThrowsAndRecordsFailedStatus() async {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: AgentLaunchConfiguration(executable: "/no/such/executable"))
        ])
        let conversationId: AgentConversationID = "conversation"

        do {
            try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
            XCTFail("Expected launch failure.")
        } catch {
            let status = await runtime.status(conversationId: conversationId)
            XCTAssertEqual(status?.state, .failed)
        }
    }

    func testLaunchFailureRejectsLaterInput() async {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: AgentLaunchConfiguration(executable: "/no/such/executable"))
        ])
        let conversationId: AgentConversationID = "conversation"

        _ = try? await runtime.spawn(conversationId: conversationId, config: spawnConfig())

        do {
            try await runtime.send(.userMessage(AgentMessageInput(text: "ignored")), conversationId: conversationId)
            XCTFail("Expected input after launch failure to be rejected.")
        } catch {
            let status = await runtime.status(conversationId: conversationId)
            XCTAssertEqual(status?.state, .failed)
        }
    }

    func testImmediateProcessExitRecordsExitStatus() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("true"))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)

        XCTAssertEqual(status?.state, .exited)
    }

    func testCancelDoesNotOverrideExitedStatus() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("true"))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        _ = await waitForExit(runtime: runtime, conversationId: conversationId)
        await runtime.cancel(conversationId: conversationId)
        let status = await runtime.status(conversationId: conversationId)

        XCTAssertEqual(status?.state, .exited)
    }

    func testCancelDoesNotOverrideFailedStatus() async {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: AgentLaunchConfiguration(executable: "/no/such/executable"))
        ])
        let conversationId: AgentConversationID = "conversation"

        _ = try? await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        await runtime.cancel(conversationId: conversationId)
        let status = await runtime.status(conversationId: conversationId)

        XCTAssertEqual(status?.state, .failed)
    }

    func testCancelAndDestroyUpdateRuntimeState() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("sleep 5"))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        await runtime.cancel(conversationId: conversationId)

        let cancelled = await runtime.status(conversationId: conversationId)
        XCTAssertEqual(cancelled?.state, .cancelled)
        try await Task.sleep(nanoseconds: 100_000_000)
        let afterExit = await runtime.status(conversationId: conversationId)
        XCTAssertEqual(afterExit?.state, .cancelled)

        await runtime.destroy(conversationId: conversationId)
        let destroyed = await runtime.status(conversationId: conversationId)
        XCTAssertNil(destroyed)
    }

    func testDestroyForceTerminatesProviderProcessThatIgnoresSoftSignals() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pidFile = directory.appendingPathComponent("provider.pid")
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("echo $$ > '\(pidFile.path)'; trap '' INT TERM; while true; do :; done"))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let pid = try await waitForProcessID(fileURL: pidFile)
        defer {
            Darwin.kill(pid, SIGKILL)
        }
        await runtime.destroy(conversationId: conversationId)
        let status = await runtime.status(conversationId: conversationId)
        let didExit = await waitForProcessExit(pid: pid)

        XCTAssertNil(status)
        XCTAssertTrue(didExit)
    }

    func testCancelRejectsLaterInputImmediately() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("sleep 5"))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        await runtime.cancel(conversationId: conversationId)

        do {
            try await runtime.send(.userMessage(AgentMessageInput(text: "ignored")), conversationId: conversationId)
            XCTFail("Expected input after cancel to be rejected.")
        } catch {
            let status = await runtime.status(conversationId: conversationId)
            XCTAssertEqual(status?.state, .cancelled)
        }
    }

    func testKillTerminatesProviderProcess() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("sleep 5"))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        await runtime.kill(conversationId: conversationId)
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)

        XCTAssertEqual(status?.state, .failed)
    }

    func testKillForceTerminatesProviderProcessThatIgnoresSoftSignals() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("trap '' INT TERM; while true; do :; done"))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        await runtime.kill(conversationId: conversationId)
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)

        XCTAssertEqual(status?.state, .failed)
    }

    func testKillRejectsLaterInputImmediately() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("sleep 5"))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        await runtime.kill(conversationId: conversationId)

        do {
            try await runtime.send(.userMessage(AgentMessageInput(text: "ignored")), conversationId: conversationId)
            XCTFail("Expected input after kill to be rejected.")
        } catch {
            let status = await waitForExit(runtime: runtime, conversationId: conversationId)
            XCTAssertEqual(status?.state, .failed)
        }
    }

    func testReconfigureDoesNotEmitFailureForReplacedProcess() async throws {
        let launchSequence = LaunchSequence([
            shell("trap '' INT TERM; while true; do :; done"),
            shell("printf 'message:new\\n'")
        ])
        let runtime = DefaultAgentRuntime(adapters: [
            SequencedProviderAdapter(launchSequence: launchSequence)
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        try await runtime.reconfigure(conversationId: conversationId, config: spawnConfig())
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { $0.event == .lifecycle(AgentLifecycleEvent(state: .exited, exitCode: 0)) }
        })
        let lifecycleStates = events.compactMap { envelope -> AgentLifecycleState? in
            guard case let .lifecycle(lifecycle) = envelope.event else {
                return nil
            }
            return lifecycle.state
        }

        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "new")) })
        XCTAssertFalse(lifecycleStates.contains(.failed))
    }

    private func waitForProcessID(fileURL: URL) async throws -> pid_t {
        for _ in 0..<100 {
            if let contents = try? String(contentsOf: fileURL, encoding: .utf8),
               let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return try XCTUnwrap(nil as pid_t?)
    }

    private func waitForProcessExit(pid: pid_t) async -> Bool {
        for _ in 0..<100 {
            if !isProcessRunning(pid: pid) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func isProcessRunning(pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }
}

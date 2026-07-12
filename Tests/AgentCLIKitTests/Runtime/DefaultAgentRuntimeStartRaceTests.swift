import XCTest

@testable import AgentCLIKit

final class DefaultAgentRuntimeStartRaceTests: XCTestCase {
    func testConcurrentStartsForSameConversationAreRejected() async throws {
        let probe = StartRaceProbe()
        let runtime = DefaultAgentRuntime(adapters: [
            DelayedStartProviderAdapter(probe: probe)
        ])
        let conversationId: AgentConversationID = "conversation"
        let config = spawnConfig()

        let firstSpawn = Task {
            try await runtime.spawn(conversationId: conversationId, config: config)
        }
        await probe.waitForStart()

        do {
            try await runtime.reconfigure(conversationId: conversationId, config: config)
            XCTFail("Expected overlapping start to fail.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error, .invalidInput("Start already in progress for conversation 'conversation'."))
        }

        try await firstSpawn.value
        let status = await runtime.status(conversationId: conversationId)

        XCTAssertEqual(status?.state, .running)
        await runtime.kill(conversationId: conversationId)
    }

    func testDestroyDuringStartCancelsPendingInstall() async throws {
        let probe = StartRaceProbe()
        let runtime = DefaultAgentRuntime(adapters: [
            DelayedStartProviderAdapter(probe: probe)
        ])
        let conversationId: AgentConversationID = "conversation"
        let config = spawnConfig()

        let spawn = Task {
            try await runtime.spawn(conversationId: conversationId, config: config)
        }
        await probe.waitForStart()

        await runtime.destroy(conversationId: conversationId)

        await assertStartWasCancelled(spawn, conversationId: conversationId)
        let status = await runtime.status(conversationId: conversationId)

        XCTAssertNil(status)
    }

    func testShutdownDuringStartCancelsPendingInstall() async throws {
        let probe = StartRaceProbe()
        let runtime = DefaultAgentRuntime(adapters: [
            DelayedStartProviderAdapter(probe: probe)
        ])
        let conversationId: AgentConversationID = "conversation"
        let config = spawnConfig()

        let spawn = Task {
            try await runtime.spawn(conversationId: conversationId, config: config)
        }
        await probe.waitForStart()

        await runtime.shutdown()

        await assertStartWasCancelled(spawn, conversationId: conversationId)
        let status = await runtime.status(conversationId: conversationId)

        XCTAssertNil(status)
    }

    func testSpawnIsRejectedWhileShutdownAwaitsProviderCleanup() async {
        let gate = ShutdownRaceGate()
        let runtime = DefaultAgentRuntime(adapters: [ShutdownBlockingProviderAdapter(gate: gate)])
        let shutdownTask = Task {
            await runtime.shutdown()
        }
        await gate.waitUntilShutdownStarted()

        do {
            try await runtime.spawn(conversationId: "conversation", config: spawnConfig())
            XCTFail("Expected spawn during shutdown to fail.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error, .invalidInput("Runtime has shut down."))
        } catch {
            XCTFail("Expected AgentCLIError, got \(error).")
        }
        await assertSubscriptionsFinish(runtime: runtime)

        await gate.finishShutdown()
        await shutdownTask.value

        do {
            try await runtime.spawn(conversationId: "after-shutdown", config: spawnConfig())
            XCTFail("Expected spawn after shutdown to fail.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error, .invalidInput("Runtime has shut down."))
        } catch {
            XCTFail("Expected AgentCLIError, got \(error).")
        }
        await assertSubscriptionsFinish(runtime: runtime)
    }

    func testDestroyDuringPreparedStartInvalidatesProviderResources() async throws {
        let startProbe = StartRaceProbe()
        let lifecycleProbe = ProviderLifecycleProbe()
        let runtime = DefaultAgentRuntime(adapters: [
            DelayedPrepareProviderAdapter(startProbe: startProbe, lifecycleProbe: lifecycleProbe)
        ])
        let conversationId: AgentConversationID = "conversation"
        let config = spawnConfig()

        let spawn = Task {
            try await runtime.spawn(conversationId: conversationId, config: config)
        }
        await startProbe.waitForStart()

        await runtime.destroy(conversationId: conversationId)

        await assertStartWasCancelled(spawn, conversationId: conversationId)
        let prepareCount = await lifecycleProbe.prepareCount
        let terminatedProcessCount = await lifecycleProbe.terminatedProcessTokens.count
        let activeProcessResources = await lifecycleProbe.activeProcessResources
        let status = await runtime.status(conversationId: conversationId)

        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(terminatedProcessCount, 2)
        XCTAssertEqual(activeProcessResources, [])
        XCTAssertNil(status)
    }

    func testDestroyHidesStateBeforeProviderCleanupCompletes() async throws {
        let gate = TerminationCleanupGate()
        let runtime = DefaultAgentRuntime(adapters: [BlockingTerminationProviderAdapter(gate: gate)])
        let conversationId: AgentConversationID = "conversation"
        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())

        let destroyTask = Task {
            await runtime.destroy(conversationId: conversationId)
        }
        await gate.waitUntilCleanupStarted()

        let status = await runtime.status(conversationId: conversationId)
        XCTAssertNil(status)
        await assertInputIsRejected(runtime: runtime, conversationId: conversationId)

        await gate.finishCleanup()
        await destroyTask.value
    }

    func testShutdownHidesStateBeforeProviderCleanupCompletes() async throws {
        let gate = TerminationCleanupGate()
        let runtime = DefaultAgentRuntime(adapters: [BlockingTerminationProviderAdapter(gate: gate)])
        let conversationId: AgentConversationID = "conversation"
        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())

        let shutdownTask = Task {
            await runtime.shutdown()
        }
        await gate.waitUntilCleanupStarted()

        let status = await runtime.status(conversationId: conversationId)
        XCTAssertNil(status)
        await assertInputIsRejected(runtime: runtime, conversationId: conversationId)

        await gate.finishCleanup()
        await shutdownTask.value
    }

    private func assertStartWasCancelled(
        _ task: Task<Void, Error>,
        conversationId: AgentConversationID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await task.value
            XCTFail("Expected start to be cancelled.", file: file, line: line)
        } catch let error as AgentCLIError {
            XCTAssertEqual(
                error,
                .invalidInput("Start was cancelled for conversation '\(conversationId.rawValue)'."),
                file: file,
                line: line
            )
        } catch {
            XCTFail("Expected AgentCLIError, got \(error).", file: file, line: line)
        }
    }

    private func assertInputIsRejected(
        runtime: DefaultAgentRuntime,
        conversationId: AgentConversationID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await runtime.send(.userMessage(AgentMessageInput(text: "late input")), conversationId: conversationId)
            XCTFail("Expected input after teardown began to fail.", file: file, line: line)
        } catch let error as AgentCLIError {
            XCTAssertEqual(
                error,
                .invalidInput("No running process for conversation '\(conversationId.rawValue)'."),
                file: file,
                line: line
            )
        } catch {
            XCTFail("Expected AgentCLIError, got \(error).", file: file, line: line)
        }
    }

    private func assertSubscriptionsFinish(
        runtime: DefaultAgentRuntime,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let subscription = await runtime.subscribe(conversationId: "shutdown-subscription", afterIndex: nil)
        var eventIterator = subscription.events.makeAsyncIterator()
        let event = await eventIterator.next()
        XCTAssertNil(event, file: file, line: line)

        let statusUpdates = await runtime.statusUpdates(conversationId: "shutdown-status")
        var statusIterator = statusUpdates.makeAsyncIterator()
        let status = await statusIterator.next()
        XCTAssertNil(status, file: file, line: line)
    }
}

private actor StartRaceProbe {
    private var didStart = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        didStart = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func waitForStart() async {
        guard !didStart else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private struct DelayedStartProviderAdapter: AgentProviderAdapter {
    let probe: StartRaceProbe
    let definition = AgentProviderDefinition(id: .claude, displayName: "Fake", executableNames: ["fake"])

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        await probe.markStarted()
        try await Task.sleep(nanoseconds: 150_000_000)
        return AgentLaunchConfiguration(executable: "/bin/sh", arguments: ["-c", "sleep 5"])
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }
}

private struct DelayedPrepareProviderAdapter: AgentProviderAdapter {
    let startProbe: StartRaceProbe
    let lifecycleProbe: ProviderLifecycleProbe
    let definition = AgentProviderDefinition(id: .claude, displayName: "Fake", executableNames: ["fake"])

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        AgentLaunchConfiguration(executable: "/bin/sh", arguments: ["-c", "sleep 5"])
    }

    func prepareLaunchConfiguration(
        _ launch: AgentLaunchConfiguration,
        spawnConfig: AgentSpawnConfig,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async throws -> AgentLaunchConfiguration {
        await lifecycleProbe.recordPrepare()
        await startProbe.markStarted()
        try await Task.sleep(nanoseconds: 150_000_000)
        await lifecycleProbe.recordProcessResource(processToken: processToken)
        return launch
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }

    func processDidTerminate(processToken: UUID) async {
        await lifecycleProbe.recordTermination(processToken: processToken)
    }
}

private actor ShutdownRaceGate {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func suspendShutdown() async {
        didStart = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }

    func waitUntilShutdownStarted() async {
        guard !didStart else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finishShutdown() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

private struct ShutdownBlockingProviderAdapter: AgentProviderAdapter {
    let gate: ShutdownRaceGate
    let definition = AgentProviderDefinition(id: .claude, displayName: "Fake", executableNames: ["fake"])

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        AgentLaunchConfiguration(executable: "/bin/true")
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }

    func shutdownProviderResources() async {
        await gate.suspendShutdown()
    }
}

private actor TerminationCleanupGate {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func suspendCleanup() async {
        didStart = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }

    func waitUntilCleanupStarted() async {
        guard !didStart else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finishCleanup() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

private struct BlockingTerminationProviderAdapter: AgentProviderAdapter {
    let gate: TerminationCleanupGate
    let definition = AgentProviderDefinition(id: .claude, displayName: "Fake", executableNames: ["fake"])

    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        AgentLaunchConfiguration(executable: "/bin/sh", arguments: ["-c", "sleep 5"])
    }

    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        []
    }

    func encodeInput(_ input: AgentInput) async throws -> Data {
        Data()
    }

    func processDidTerminate(processToken: UUID) async {
        await gate.suspendCleanup()
    }
}

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
        let status = await runtime.status(conversationId: conversationId)

        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(terminatedProcessCount, 1)
        XCTAssertNil(status)
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

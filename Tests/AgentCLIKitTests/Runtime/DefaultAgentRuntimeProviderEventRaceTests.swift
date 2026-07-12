import XCTest

@testable import AgentCLIKit

final class RuntimeProviderEventRaceTests: XCTestCase {
    func testDestroyWhileRuntimeEventSubscriptionStartsCancelsStaleStream() async throws {
        let gate = ProviderRuntimeEventStartGate()
        let runtime = DefaultAgentRuntime(adapters: [GatedRuntimeEventProviderAdapter(gate: gate)])
        let conversationId: AgentConversationID = "conversation"
        let config = spawnConfig()

        let spawn = Task {
            try await runtime.spawn(conversationId: conversationId, config: config)
        }
        await gate.waitUntilStarted()

        await runtime.destroy(conversationId: conversationId)
        await gate.release()
        do {
            try await spawn.value
            XCTFail("Expected the destroyed start to be cancelled.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Start was cancelled"))
        }

        for _ in 0..<100 {
            guard !(await gate.streamWasTerminated) else {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let streamWasTerminated = await gate.streamWasTerminated
        let status = await runtime.status(conversationId: conversationId)
        XCTAssertTrue(streamWasTerminated)
        XCTAssertNil(status)
    }
}

private actor ProviderRuntimeEventStartGate {
    private var didStart = false
    private var isReleased = false
    private(set) var streamWasTerminated = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspendUntilReleased() async {
        didStart = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        guard !isReleased else {
            return
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !didStart else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }

    func markStreamTerminated() {
        streamWasTerminated = true
    }
}

private struct GatedRuntimeEventProviderAdapter: AgentProviderAdapter {
    let gate: ProviderRuntimeEventStartGate
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

    func runtimeEvents(context: AgentProviderRuntimeContext) async -> AsyncStream<AgentProviderRuntimeEvent> {
        await gate.suspendUntilReleased()
        return AsyncStream { continuation in
            continuation.onTermination = { _ in
                Task {
                    await gate.markStreamTerminated()
                }
            }
        }
    }
}

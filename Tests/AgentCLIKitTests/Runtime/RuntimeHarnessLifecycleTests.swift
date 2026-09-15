import XCTest

@testable import AgentCLIKit

final class RuntimeHarnessLifecycleTests: XCTestCase {
    func testSpawnUsesHarnessPreparedLaunchConfiguration() async throws {
        let probe = HarnessLifecycleProbe()
        let runtime = DefaultAgentRuntime(adapters: [
            LifecycleTrackingHarnessAdapter(
                command: shell(#"printf "message:$AGENTCLIKIT_TEST_PREPARED\n""#),
                probe: probe
            )
        ])
        let conversationId: AgentConversationID = "conversation"
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())

        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "prepared")) }
        })
        let prepareCount = await probe.prepareCount

        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "prepared")) })
        XCTAssertEqual(prepareCount, 1)
    }

    func testSpawnFailsWhenHarnessPreparedLaunchConfigurationFails() async throws {
        let probe = HarnessLifecycleProbe()
        let runtime = DefaultAgentRuntime(adapters: [
            FailingPrepareHarnessAdapter(command: shell(#"printf "message:unreachable\n""#), probe: probe)
        ])
        let conversationId: AgentConversationID = "conversation"

        do {
            try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
            XCTFail("Expected harness launch preparation to fail.")
        } catch {
            let terminatedProcessCount = await probe.terminatedProcessTokens.count
            let status = await runtime.status(conversationId: conversationId)
            XCTAssertEqual(error as? AgentCLIError, .invalidInput("prepare failed"))
            XCTAssertEqual(terminatedProcessCount, 1)
            XCTAssertNil(status)
        }
    }

    func testShutdownNotifiesHarnessLifecycle() async throws {
        let probe = HarnessLifecycleProbe()
        let runtime = DefaultAgentRuntime(adapters: [
            LifecycleTrackingHarnessAdapter(command: shell("sleep 5"), probe: probe)
        ])

        try await runtime.spawn(conversationId: "conversation", config: spawnConfig())
        await runtime.shutdown()
        let terminatedProcessCount = await probe.terminatedProcessTokens.count
        let shutdownCount = await probe.shutdownCount

        XCTAssertEqual(terminatedProcessCount, 1)
        XCTAssertEqual(shutdownCount, 1)
    }

    func testShutdownFinishesActiveSubscribers() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            LifecycleTrackingHarnessAdapter(command: shell("sleep 5"), probe: HarnessLifecycleProbe())
        ])
        let conversationId: AgentConversationID = "conversation"
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let collector = Task {
            for await _ in subscription.events {}
            return true
        }

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        await runtime.shutdown()
        let didFinish = await Self.raceAgainstTimeout(collector)

        XCTAssertTrue(didFinish)
    }

    private static func raceAgainstTimeout(_ task: Task<Bool, Never>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                task.cancel()
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}

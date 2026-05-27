import XCTest

@testable import AgentCLIKit

final class DefaultAgentRuntimeBackpressureTests: XCTestCase {
    func testSlowSubscriberUsesBoundedBufferAndReplayKeepsEvents() async throws {
        let runtime = DefaultAgentRuntime(
            adapters: [
                FakeProviderAdapter(command: shell("""
                i=1
                while [ "$i" -le 20 ]; do
                  printf "message:line-$i\\n"
                  i=$((i + 1))
                done
                """))
            ],
            subscriberBufferLimit: 5
        )
        let conversationId: AgentConversationID = "conversation"

        let slowSubscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)

        let buffered = await Self.collect(slowSubscription.events, limit: 10)
        let replay = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let replayed = await Self.collect(replay.events, limit: (status?.lastEventIndex ?? -1) + 1)
        let replayedMessages = replayed.compactMap { envelope -> String? in
            guard case let .message(message) = envelope.event else {
                return nil
            }
            return message.text
        }

        XCTAssertLessThanOrEqual(buffered.count, 5)
        XCTAssertTrue(buffered.contains { $0.event == .lifecycle(AgentLifecycleEvent(state: .exited, exitCode: 0)) })
        XCTAssertEqual(replayedMessages.count, 20)
        XCTAssertEqual(replayedMessages.first, "line-1")
        XCTAssertEqual(replayedMessages.last, "line-20")
    }

    func testRuntimeDrainsLargeStdoutAndStderrStreams() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: shell("""
            i=1
            while [ "$i" -le 250 ]; do
              printf "message:line-$i\\n"
              i=$((i + 1))
            done
            j=1
            while [ "$j" -le 50 ]; do
              printf "err-$j\\n" >&2
              j=$((j + 1))
            done
            """))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)
        let replay = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let replayed = await Self.collect(replay.events, limit: (status?.lastEventIndex ?? -1) + 1)
        let messages = replayed.compactMap { envelope -> String? in
            guard case let .message(message) = envelope.event else {
                return nil
            }
            return message.text
        }
        let diagnostics = replayed.compactMap { envelope -> AgentDiagnosticEvent? in
            guard case let .diagnostic(diagnostic) = envelope.event else {
                return nil
            }
            return diagnostic
        }

        XCTAssertEqual(messages.count, 250)
        XCTAssertEqual(messages.first, "line-1")
        XCTAssertEqual(messages.last, "line-250")
        XCTAssertEqual(diagnostics.count, 50)
        XCTAssertEqual(Set(diagnostics.map(\.code)), [.providerStderr])
        XCTAssertTrue(diagnostics.contains { $0.message == "err-1" })
        XCTAssertTrue(diagnostics.contains { $0.message == "err-50" })
    }
}

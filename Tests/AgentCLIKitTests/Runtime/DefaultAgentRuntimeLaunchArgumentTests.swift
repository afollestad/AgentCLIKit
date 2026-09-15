import Foundation
import XCTest

@testable import AgentCLIKit

extension DefaultAgentRuntimeTests {
    func testRuntimeAppendsSpawnArgumentsWhenLaunchDoesNotIncludeThem() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeHarnessAdapter(command: AgentLaunchConfiguration(executable: "/usr/bin/printf", arguments: ["%s\n"]))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(
            conversationId: conversationId,
            config: AgentSpawnConfig(
                harnessId: .claude,
                workingDirectory: FileManager.default.temporaryDirectory,
                arguments: ["message:spawn"]
            )
        )
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "spawn")) }
        })

        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "spawn")) })
    }

    func testRuntimeDoesNotAppendSpawnArgumentsWhenLaunchAlreadyIncludesThem() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeHarnessAdapter(command: AgentLaunchConfiguration(
                executable: "/usr/bin/printf",
                arguments: ["%s\n", "message:harness"],
                includesSpawnArguments: true
            ))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(
            conversationId: conversationId,
            config: AgentSpawnConfig(
                harnessId: .claude,
                workingDirectory: FileManager.default.temporaryDirectory,
                arguments: ["message:spawn"]
            )
        )
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let events = await Self.collect(subscription.events, limit: 4)

        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "harness")) })
        XCTAssertFalse(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "spawn")) })
    }

    func testRuntimeWritesInitialPromptOverStdinWhenLaunchRequestsIt() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeHarnessAdapter(command: AgentLaunchConfiguration(
                executable: "/bin/sh",
                arguments: ["-c", "IFS= read -r line; printf 'message:%s\\n' \"$line\""],
                sendsInitialPromptOverStdin: true
            ))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(
            conversationId: conversationId,
            config: AgentSpawnConfig(
                harnessId: .claude,
                workingDirectory: FileManager.default.temporaryDirectory,
                initialPrompt: "hello from startup"
            )
        )
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let events = await Self.collect(subscription.events, until: { envelopes in
            envelopes.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "hello from startup")) }
        })

        XCTAssertTrue(events.contains {
            $0.event == .message(AgentMessageEvent(role: .assistant, text: "hello from startup"))
        })
    }
}

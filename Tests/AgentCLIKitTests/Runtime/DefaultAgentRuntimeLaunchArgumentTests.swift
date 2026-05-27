import Foundation
import XCTest

@testable import AgentCLIKit

extension DefaultAgentRuntimeTests {
    func testRuntimeAppendsSpawnArgumentsWhenLaunchDoesNotIncludeThem() async throws {
        let runtime = DefaultAgentRuntime(adapters: [
            FakeProviderAdapter(command: AgentLaunchConfiguration(executable: "/usr/bin/printf", arguments: ["%s\n"]))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(
            conversationId: conversationId,
            config: AgentSpawnConfig(
                providerId: .claude,
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
            FakeProviderAdapter(command: AgentLaunchConfiguration(
                executable: "/usr/bin/printf",
                arguments: ["%s\n", "message:provider"],
                includesSpawnArguments: true
            ))
        ])
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(
            conversationId: conversationId,
            config: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: FileManager.default.temporaryDirectory,
                arguments: ["message:spawn"]
            )
        )
        let subscription = await runtime.subscribe(conversationId: conversationId, afterIndex: nil)
        let events = await Self.collect(subscription.events, limit: 4)

        XCTAssertTrue(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "provider")) })
        XCTAssertFalse(events.contains { $0.event == .message(AgentMessageEvent(role: .assistant, text: "spawn")) })
    }
}

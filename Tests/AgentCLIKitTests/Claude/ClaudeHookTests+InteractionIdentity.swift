import XCTest

@testable import AgentCLIKit

extension ClaudeHookTests {
    func testPreToolUseAcceptsToolUseIDAsInteractionIdentity() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)

        let response = await server.handle(preToolUse(
            token: token.value,
            toolUseId: "tool-upper-d",
            toolUseIdKey: "toolUseID"
        ))
        let pending = await interactionStore.pending(conversationId: "conversation")

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .deferDecision)
        XCTAssertEqual(pending.first?.id, "tool-upper-d")
        XCTAssertEqual(pending.first?.approvalRequest?.id, "tool-upper-d")
    }

    func testPreToolUseWithoutToolUseIDUsesStableFallbackInteractionIdentity() async throws {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let approvalPolicyStore = ClaudeApprovalPolicyStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(
            tokenStore: tokenStore,
            interactionStore: interactionStore,
            approvalPolicyStore: approvalPolicyStore
        )
        let hookRequest = preToolUse(
            token: token.value,
            toolUseId: nil,
            toolName: "Bash",
            toolInput: .object(["command": .string("git status")])
        )

        let deferred = await server.handle(hookRequest)
        let pending = await interactionStore.pending(conversationId: "conversation")
        let fallbackId = try XCTUnwrap(pending.first?.id)
        await approvalPolicyStore.approveBatch([fallbackId])
        let allowed = await server.handle(hookRequest)
        let record = await interactionStore.record(id: fallbackId)

        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: deferred), .deferDecision)
        XCTAssertTrue(fallbackId.rawValue.hasPrefix("hook-"))
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: allowed), .allow)
        XCTAssertEqual(record?.resolution?.outcome, .approved)
    }
}

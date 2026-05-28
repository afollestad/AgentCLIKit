import XCTest

@testable import AgentCLIKit

extension ClaudeHookTests {
    func testSessionApprovalCanMatchProviderNeutralGrant() async throws {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let approvalPolicyStore = ClaudeApprovalPolicyStore()
        let token = await tokenStore.issue(validFor: 60)
        let request = AgentSessionApprovalRequest(
            providerId: .claude,
            conversationId: "conversation",
            sessionId: "session-123",
            toolName: "Bash",
            toolInput: .object(["command": .string("git add Package.swift")])
        )
        let grant = try XCTUnwrap(request.sessionApprovalGrant(for: .group))
        _ = await approvalPolicyStore.recordSessionApproval(grant)
        let server = ClaudeHookServer(
            tokenStore: tokenStore,
            interactionStore: interactionStore,
            approvalPolicyStore: approvalPolicyStore
        )

        let allowed = await server.handle(preToolUse(
            token: token.value,
            toolName: "Bash",
            toolInput: .object(["command": .string("git add Sources/App.swift")])
        ))
        let deferred = await server.handle(preToolUse(
            token: token.value,
            toolName: "Bash",
            toolInput: .object(["command": .string("git status")])
        ))

        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: allowed), .allow)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: deferred), .deferDecision)
    }
}

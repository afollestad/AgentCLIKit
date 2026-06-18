import XCTest

@testable import AgentCLIKit

extension ClaudeHookTests {
    func testPreToolUseProvidesApprovalIdentityToLiveDecisionProvider() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let decisionProvider = ApprovalIDDecisionProvider(decision: .allow())
        let server = ClaudeHookServer(
            tokenStore: tokenStore,
            interactionStore: interactionStore,
            decisionProvider: decisionProvider
        )

        _ = await server.handle(preToolUse(
            token: token.value,
            toolName: "Bash",
            toolInput: .object(["command": .string(#"/bin/zsh -lc 'git add README.md'"#)])
        ))
        let request = await decisionProvider.request()

        XCTAssertEqual(request?.approvalIdentityToolInput, .object(["command": .string("git add README.md")]))
    }
}

private actor ApprovalIDDecisionProvider: ClaudeHookDecisionProviding {
    let decision: ClaudeHookDecision
    private var capturedRequest: ClaudeHookRequest?

    init(decision: ClaudeHookDecision) {
        self.decision = decision
    }

    func decision(for request: ClaudeHookRequest, interactionId: AgentInteractionID) async -> ClaudeHookDecision {
        capturedRequest = request
        return decision
    }

    func request() -> ClaudeHookRequest? {
        capturedRequest
    }
}

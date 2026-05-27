import XCTest

@testable import AgentCLIKit

extension ClaudeHookTests {
    func testPreToolUseAllowsEditInAcceptEditsModeWithoutStoringInteraction() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)

        let response = await server.handle(preToolUse(token: token.value, toolName: "Edit", permissionMode: "acceptEdits"))
        let pending = await interactionStore.pending(conversationId: "conversation")

        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .allow)
        XCTAssertEqual(pending, [])
    }

    func testPreToolUseStillDefersBashAndMutatingMCPInAcceptEditsMode() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)

        let bash = await server.handle(preToolUse(token: token.value, toolName: "Bash", permissionMode: "acceptEdits"))
        let mcp = await server.handle(preToolUse(token: token.value, toolName: "mcp__repo__write_file", permissionMode: "acceptEdits"))

        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: bash), .deferDecision)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: mcp), .deferDecision)
    }

    func testPreToolUseAllowsToolsInAutoBypassAndDontAskModes() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)

        for mode in ["auto", "bypassPermissions", "dontAsk"] {
            let response = await server.handle(preToolUse(token: token.value, toolName: "Bash", permissionMode: mode))
            XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .allow)
        }

        let pending = await interactionStore.pending(conversationId: "conversation")
        XCTAssertEqual(pending, [])
    }

    func testPreToolUseAllowsReadOnlyMCPInAcceptEditsMode() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)

        let response = await server.handle(preToolUse(
            token: token.value,
            toolName: "mcp__repo__read_file",
            permissionMode: "acceptEdits"
        ))

        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .allow)
    }

    func testPreToolUseExitPlanModeOnlyDefersInPlanMode() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)

        let defaultMode = await server.handle(preToolUse(
            token: token.value,
            toolName: "ExitPlanMode",
            permissionMode: "default"
        ))
        let planMode = await server.handle(preToolUse(token: token.value, toolName: "ExitPlanMode", permissionMode: "plan"))
        let pending = await interactionStore.pending(conversationId: "conversation")

        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: defaultMode), .allow)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: planMode), .deferDecision)
        XCTAssertEqual(pending.first?.kind, .planModeExit)
    }
}

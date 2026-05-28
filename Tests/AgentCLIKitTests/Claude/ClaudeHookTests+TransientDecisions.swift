import XCTest

@testable import AgentCLIKit

extension ClaudeHookTests {
    func testApprovalPolicySupportsSessionAndTransientApprovals() async {
        let store = ClaudeApprovalPolicyStore()
        let id: AgentInteractionID = "approval"

        await store.approveForSession(operation: "Edit")
        await store.approveBatch([id])

        let sessionApproved = await store.isSessionApproved(operation: "Edit")
        let firstTransient = await store.consumeTransientApproval(id: id)
        let secondTransient = await store.consumeTransientApproval(id: id)
        await store.recordTransientDecision(.deny(reason: "No"), id: id)
        let deniedTransient = await store.consumeTransientDecision(id: id)
        await store.recordTransientDecision(
            .allow(reason: "Scoped"),
            for: ClaudeTransientDecisionKey(sessionId: "session", interactionId: id)
        )
        let scopedTransient = await store.consumeTransientDecision(
            for: ClaudeTransientDecisionKey(sessionId: "session", interactionId: id)
        )
        await store.recordTransientDecision(.deny(reason: "Legacy"), id: id)
        await store.recordTransientDecision(
            .allow(reason: "Scoped discard"),
            for: ClaudeTransientDecisionKey(sessionId: "session", interactionId: id)
        )
        await store.discardTransientDecision(for: ClaudeTransientDecisionKey(sessionId: "session", interactionId: id))
        let preservedLegacyTransient = await store.consumeTransientDecision(id: id)

        XCTAssertTrue(sessionApproved)
        XCTAssertTrue(firstTransient)
        XCTAssertFalse(secondTransient)
        XCTAssertEqual(deniedTransient?.approval, .deny)
        XCTAssertEqual(deniedTransient?.reason, "No")
        XCTAssertEqual(scopedTransient?.approval, .allow)
        XCTAssertEqual(scopedTransient?.reason, "Scoped")
        XCTAssertEqual(preservedLegacyTransient?.approval, .deny)
        XCTAssertEqual(preservedLegacyTransient?.reason, "Legacy")
    }

    func testPreToolUseConsumesTransientDenyDecisionForStableToolUseID() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let approvalPolicyStore = ClaudeApprovalPolicyStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(
            tokenStore: tokenStore,
            interactionStore: interactionStore,
            approvalPolicyStore: approvalPolicyStore
        )

        let deferred = await server.handle(preToolUse(token: token.value))
        await approvalPolicyStore.recordTransientDecision(.deny(reason: "Denied after fallback."), id: "tool-1")
        let denied = await server.handle(preToolUse(token: token.value))
        let record = await interactionStore.record(id: "tool-1")

        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: deferred), .deferDecision)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: denied), .deny)
        XCTAssertEqual(record?.resolution?.outcome, .denied)
        XCTAssertEqual(record?.resolution?.responseText, "Denied after fallback.")
    }

    func testPreToolUseAskUserQuestionConsumesTransientUpdatedInput() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let approvalPolicyStore = ClaudeApprovalPolicyStore()
        let token = await tokenStore.issue(validFor: 60)
        let originalInput: JSONValue = .object([
            "questions": .array([.object(["question": .string("Pick one")])])
        ])
        let updatedInput: JSONValue = .object([
            "questions": .array([.object(["question": .string("Pick one")])]),
            "answers": .object(["0": .string("A")])
        ])
        let server = ClaudeHookServer(
            tokenStore: tokenStore,
            interactionStore: interactionStore,
            approvalPolicyStore: approvalPolicyStore
        )

        let deferred = await server.handle(preToolUse(token: token.value, toolName: "AskUserQuestion", toolInput: originalInput))
        await approvalPolicyStore.recordTransientDecision(.allow(updatedInput: updatedInput), id: "tool-1")
        let allowed = await server.handle(preToolUse(token: token.value, toolName: "AskUserQuestion", toolInput: originalInput))
        let output = hookSpecificOutput(from: allowed)
        let record = await interactionStore.record(id: "tool-1")

        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: deferred), .deferDecision)
        XCTAssertEqual(output?["permissionDecision"], .string("allow"))
        XCTAssertEqual(output?["updatedInput"], updatedInput)
        XCTAssertEqual(record?.resolution?.outcome, .answered)
        XCTAssertEqual(record?.resolution?.metadata["updated_input"], updatedInput)
    }

    func testPreToolUseDoesNotConsumeTransientDecisionForDifferentSession() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let approvalPolicyStore = ClaudeApprovalPolicyStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(
            tokenStore: tokenStore,
            interactionStore: interactionStore,
            approvalPolicyStore: approvalPolicyStore
        )
        let key = ClaudeTransientDecisionKey(sessionId: "session-123", interactionId: "tool-1")

        await approvalPolicyStore.recordTransientDecision(.deny(reason: "Denied after fallback."), for: key)
        let wrongSession = await server.handle(preToolUse(token: token.value, sessionId: "session-456"))
        let matchingSession = await server.handle(preToolUse(token: token.value, sessionId: "session-123"))

        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: wrongSession), .deferDecision)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: matchingSession), .deny)
    }

    private func hookSpecificOutput(from response: AgentHookResponse) -> [String: JSONValue]? {
        guard case let .object(body)? = response.body,
              case let .object(output)? = body["hookSpecificOutput"] else {
            return nil
        }
        return output
    }
}

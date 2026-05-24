import XCTest

@testable import AgentCLIKit

final class ClaudeHookTests: XCTestCase {
    func testHookSettingsGenerationUsesSharedPreToolUseMatcher() throws {
        let endpointURL = try XCTUnwrap(URL(string: "http://127.0.0.1:1234/claude/hooks/pre-tool-use"))
        let settings = ClaudeHookSettings(
            endpointURL: endpointURL,
            tokenEnvironmentVariable: "CLAUDE_HOOK_TOKEN",
            timeoutSeconds: 30
        )

        let data = try settings.encodedData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        let matcher = try XCTUnwrap(preToolUse.first)
        let transports = try XCTUnwrap(matcher["hooks"] as? [[String: Any]])
        let transport = try XCTUnwrap(transports.first)

        XCTAssertEqual(matcher["matcher"] as? String, ClaudeHookPolicy.preToolUseMatcher)
        XCTAssertEqual(transport["type"] as? String, "http")
        XCTAssertEqual(transport["url"] as? String, endpointURL.absoluteString)
        XCTAssertEqual(transport["timeout"] as? Int, 30)
        XCTAssertEqual((transport["headers"] as? [String: String])?["Authorization"], "Bearer $CLAUDE_HOOK_TOKEN")
        XCTAssertEqual(transport["allowedEnvVars"] as? [String], ["CLAUDE_HOOK_TOKEN"])
    }

    func testHookTimeoutDefaultsLeaveDecisionBuffer() throws {
        let endpointURL = try XCTUnwrap(URL(string: "http://127.0.0.1:1234/claude/hooks/pre-tool-use"))
        let settings = ClaudeHookSettings(endpointURL: endpointURL)

        let data = try settings.encodedData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        let matcher = try XCTUnwrap(preToolUse.first)
        let transports = try XCTUnwrap(matcher["hooks"] as? [[String: Any]])
        let transport = try XCTUnwrap(transports.first)

        XCTAssertEqual(transport["timeout"] as? Int, ClaudeHookPolicy.defaultHookTimeoutSeconds)
        XCTAssertLessThan(ClaudeHookPolicy.defaultDecisionTimeout, TimeInterval(ClaudeHookPolicy.defaultHookTimeoutSeconds))
    }

    func testHookRejectsInvalidTokenAndInvalidatesValidToken() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)
        let token = await tokenStore.issue(validFor: 60)

        let invalid = await server.handle(preToolUse(token: "bad"))
        XCTAssertEqual(invalid.statusCode, 200)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: invalid), .deny)

        await server.invalidateToken(token.value)
        let invalidated = await server.handle(preToolUse(token: token.value))
        XCTAssertEqual(invalidated.statusCode, 200)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: invalidated), .deny)
    }

    func testPreToolUseStoresApprovalAndUsesLiveDecision() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let decisionProvider = CapturingDecisionProvider(decision: .allow())
        let server = ClaudeHookServer(
            tokenStore: tokenStore,
            interactionStore: interactionStore,
            decisionProvider: decisionProvider
        )

        let response = await server.handle(preToolUse(token: token.value))
        let pending = await interactionStore.pending(conversationId: "conversation")
        let interactionId = await decisionProvider.interactionId()
        let record: AgentInteractionRecord?
        if let interactionId {
            record = await interactionStore.record(id: interactionId)
        } else {
            record = nil
        }

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .allow)
        XCTAssertEqual(pending, [])
        XCTAssertEqual(record?.resolution?.outcome, .approved)
    }

    func testPreToolUseDefersWhenNoLiveDecisionProviderExists() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)

        let response = await server.handle(preToolUse(token: token.value))
        let pending = await interactionStore.pending(conversationId: "conversation")

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .deferDecision)
        XCTAssertEqual(pending.first?.approvalRequest?.operation, "Edit")
    }

    func testPreToolUseStoresCurrentPermissionModeOnApproval() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)

        _ = await server.handle(preToolUse(token: token.value, permissionMode: "plan"))
        let response = await server.handle(preToolUse(token: token.value, permissionMode: nil))
        let pending = await interactionStore.pending(conversationId: "conversation")

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(pending.last?.approvalRequest?.permissionMode, "plan")
    }

    func testPreToolUseDefersWhenLiveDecisionTimesOut() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(
            tokenStore: tokenStore,
            interactionStore: interactionStore,
            decisionProvider: SlowDecisionProvider(delayNanoseconds: 1_000_000_000),
            decisionTimeout: 0.01
        )

        let response = await server.handle(preToolUse(token: token.value))
        let pending = await interactionStore.pending(conversationId: "conversation")
        let record = await interactionStore.record(id: "tool-1")

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .deferDecision)
        XCTAssertEqual(pending.first?.approvalRequest?.operation, "Edit")
        XCTAssertNil(record?.resolution)
    }

    func testPreToolUseAllowsSessionApprovedOperation() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let approvalPolicyStore = ClaudeApprovalPolicyStore()
        let token = await tokenStore.issue(validFor: 60)
        await approvalPolicyStore.approveForSession(operation: "Edit")
        let server = ClaudeHookServer(
            tokenStore: tokenStore,
            interactionStore: interactionStore,
            approvalPolicyStore: approvalPolicyStore
        )

        let response = await server.handle(preToolUse(token: token.value))
        let pending = await interactionStore.pending(conversationId: "conversation")

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .allow)
        XCTAssertEqual(pending, [])
    }

    func testSessionApprovalCanMatchExactToolInput() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let approvalPolicyStore = ClaudeApprovalPolicyStore()
        let token = await tokenStore.issue(validFor: 60)
        let toolInput: JSONValue = .object(["file_path": .string("README.md")])
        await approvalPolicyStore.approveForSession(operation: "Edit", input: toolInput)
        let server = ClaudeHookServer(
            tokenStore: tokenStore,
            interactionStore: interactionStore,
            approvalPolicyStore: approvalPolicyStore
        )

        let allowed = await server.handle(preToolUse(token: token.value, toolInput: toolInput))
        let deferred = await server.handle(preToolUse(
            token: token.value,
            toolInput: .object(["file_path": .string("Package.swift")])
        ))

        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: allowed), .allow)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: deferred), .deferDecision)
    }

    func testPreToolUseConsumesTransientApprovalForStableToolUseID() async {
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
        await approvalPolicyStore.approveBatch(["tool-1"])
        let allowed = await server.handle(preToolUse(token: token.value))
        let record = await interactionStore.record(id: "tool-1")

        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: deferred), .deferDecision)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: allowed), .allow)
        XCTAssertEqual(record?.resolution?.outcome, .approved)
    }

    func testPreToolUseAskUserQuestionStoresPromptAndDefers() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)
        let payload: JSONValue = .object([
            "questions": .array([
                .object([
                    "question": .string("Pick one"),
                    "options": .array([
                        .object(["label": .string("A"), "description": .string("First")])
                    ])
                ])
            ])
        ])

        let response = await server.handle(preToolUse(token: token.value, toolName: "AskUserQuestion", toolInput: payload))
        let pending = await interactionStore.pending(conversationId: "conversation")

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .deferDecision)
        XCTAssertEqual(pending.first?.kind, .prompt)
        XCTAssertEqual(pending.first?.promptRequest?.prompt, "Pick one")
        XCTAssertEqual(pending.first?.promptRequest?.options, [
            AgentPromptOption(
                id: "0",
                label: "A",
                responseText: "A",
                metadata: ["label": .string("A"), "description": .string("First")]
            )
        ])
        XCTAssertTrue(pending.first?.promptRequest?.allowsCustomResponse == true)
    }

    func testPreToolUseEnterPlanModeAllowsWithoutStoringInteraction() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)

        let response = await server.handle(preToolUse(token: token.value, toolName: "EnterPlanMode"))
        let pending = await interactionStore.pending(conversationId: "conversation")

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .allow)
        XCTAssertEqual(pending, [])
    }

    func testPreToolUseAskUserQuestionLiveDecisionReturnsUpdatedInput() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let updatedInput: JSONValue = .object([
            "questions": .array([.object(["question": .string("Pick one")])]),
            "answers": .object(["0": .string("A")])
        ])
        let server = ClaudeHookServer(
            tokenStore: tokenStore,
            interactionStore: interactionStore,
            decisionProvider: StaticDecisionProvider(decision: .allow(updatedInput: updatedInput))
        )

        let response = await server.handle(preToolUse(
            token: token.value,
            toolName: "AskUserQuestion",
            toolInput: .object(["questions": .array([.object(["question": .string("Pick one")])])])
        ))
        let output = hookSpecificOutput(from: response)
        let record = await interactionStore.record(id: "tool-1")

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(output?["permissionDecision"], .string("allow"))
        XCTAssertEqual(output?["updatedInput"], updatedInput)
        XCTAssertEqual(record?.resolution?.outcome, .answered)
        XCTAssertEqual(record?.resolution?.metadata["updated_input"], updatedInput)
    }

    func testPreToolUseExitPlanModeStoresPlanInteractionAndDefers() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)

        let response = await server.handle(preToolUse(token: token.value, toolName: "ExitPlanMode"))
        let pending = await interactionStore.pending(conversationId: "conversation")

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .deferDecision)
        XCTAssertEqual(pending.first?.kind, .planModeExit)
        XCTAssertEqual(pending.first?.approvalRequest?.operation, "ExitPlanMode")
    }

    func testSessionApprovedExitPlanModeEchoesOriginalToolInput() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let approvalPolicyStore = ClaudeApprovalPolicyStore()
        let token = await tokenStore.issue(validFor: 60)
        let toolInput: JSONValue = .object(["plan": .string("Ship it")])
        await approvalPolicyStore.approveForSession(operation: "ExitPlanMode")
        let server = ClaudeHookServer(
            tokenStore: tokenStore,
            interactionStore: interactionStore,
            approvalPolicyStore: approvalPolicyStore
        )

        let response = await server.handle(preToolUse(token: token.value, toolName: "ExitPlanMode", toolInput: toolInput))
        let output = hookSpecificOutput(from: response)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(output?["permissionDecision"], .string("allow"))
        XCTAssertEqual(output?["updatedInput"], toolInput)
    }

    func testPreToolUseDenialReturnsSuccessfulDenyDecision() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(
            tokenStore: tokenStore,
            interactionStore: interactionStore,
            decisionProvider: StaticDecisionProvider(decision: .deny())
        )

        let response = await server.handle(preToolUse(token: token.value))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .deny)
    }

    func testAskUserQuestionAndPlanModeExitResponses() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)

        let question = await server.handle(ClaudeHookRequest(
            bearerToken: token.value,
            hookName: "AskUserQuestion",
            conversationId: "conversation",
            payload: .object(["question": .string("Proceed?")])
        ))
        let planExit = await server.handle(ClaudeHookRequest(
            bearerToken: token.value,
            hookName: "PlanModeExit",
            conversationId: "conversation",
            payload: .object([:])
        ))
        let pending = await interactionStore.pending(conversationId: "conversation")

        XCTAssertEqual(question.statusCode, 200)
        XCTAssertEqual(pending.first?.promptRequest?.prompt, "Proceed?")
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: planExit), .deferDecision)
        XCTAssertTrue(pending.contains { $0.kind == .planModeExit })
    }

    func testApprovalPolicySupportsSessionAndTransientApprovals() async {
        let store = ClaudeApprovalPolicyStore()
        let id: AgentInteractionID = "approval"

        await store.approveForSession(operation: "Edit")
        await store.approveBatch([id])

        let sessionApproved = await store.isSessionApproved(operation: "Edit")
        let firstTransient = await store.consumeTransientApproval(id: id)
        let secondTransient = await store.consumeTransientApproval(id: id)
        XCTAssertTrue(sessionApproved)
        XCTAssertTrue(firstTransient)
        XCTAssertFalse(secondTransient)
    }

    func testResponseMapperFailsClosedForAmbiguous2xx() {
        let response = AgentHookResponse(statusCode: 200, body: .object([:]))

        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .deny)
    }

    func testResponseMapperUnderstandsClaudeHookSpecificOutput() {
        let response = AgentHookResponse(statusCode: 200, body: .object([
            "hookSpecificOutput": .object([
                "permissionDecision": .string("allow")
            ])
        ]))

        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .allow)
    }

    private func preToolUse(
        token: String?,
        toolName: String = "Edit",
        toolInput: JSONValue = .object([:]),
        permissionMode: String? = nil
    ) -> ClaudeHookRequest {
        var payload: [String: JSONValue] = [
            "hook_event_name": .string("PreToolUse"),
            "session_id": .string("session-123"),
            "tool_use_id": .string("tool-1"),
            "tool_name": .string(toolName),
            "tool_input": toolInput
        ]
        if let permissionMode {
            payload["permissionMode"] = .string(permissionMode)
        }
        return ClaudeHookRequest(
            bearerToken: token,
            hookName: "PreToolUse",
            conversationId: "conversation",
            payload: .object(payload)
        )
    }

    private func hookSpecificOutput(from response: AgentHookResponse) -> [String: JSONValue]? {
        guard case let .object(body)? = response.body,
              case let .object(output)? = body["hookSpecificOutput"] else {
            return nil
        }
        return output
    }
}

private struct StaticDecisionProvider: ClaudeHookDecisionProviding {
    let decision: ClaudeHookDecision

    func decision(for request: ClaudeHookRequest, interactionId: AgentInteractionID) async -> ClaudeHookDecision {
        decision
    }
}

private struct SlowDecisionProvider: ClaudeHookDecisionProviding {
    let delayNanoseconds: UInt64

    func decision(for request: ClaudeHookRequest, interactionId: AgentInteractionID) async -> ClaudeHookDecision {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        return .allow()
    }
}

private actor CapturingDecisionProvider: ClaudeHookDecisionProviding {
    let decision: ClaudeHookDecision
    private var capturedInteractionId: AgentInteractionID?

    init(decision: ClaudeHookDecision) {
        self.decision = decision
    }

    func decision(for request: ClaudeHookRequest, interactionId: AgentInteractionID) async -> ClaudeHookDecision {
        capturedInteractionId = interactionId
        return decision
    }

    func interactionId() -> AgentInteractionID? {
        capturedInteractionId
    }
}

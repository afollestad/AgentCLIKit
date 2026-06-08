import XCTest

@testable import AgentCLIKit

final class ClaudeHookDecisionRaceTests: XCTestCase {
    func testLateLiveDecisionAfterTimeoutDoesNotResolveDeferredInteraction() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let server = ClaudeHookServer(
            tokenStore: tokenStore,
            interactionStore: interactionStore,
            decisionProvider: SlowDecisionProvider(delayNanoseconds: 50_000_000),
            decisionTimeout: 0.01
        )

        let response = await server.handle(preToolUse(token: token.value))
        try? await Task.sleep(nanoseconds: 100_000_000)
        let record = await interactionStore.record(id: "tool-1")

        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: response), .deferDecision)
        XCTAssertNil(record?.resolution)
    }

    func testTokenInvalidationReleasesPendingLiveDecisionWithoutResolvingInteraction() async {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let token = await tokenStore.issue(validFor: 60)
        let decisionProvider = HangingSignalingDecisionProvider()
        let server = ClaudeHookServer(
            tokenStore: tokenStore,
            interactionStore: interactionStore,
            decisionProvider: decisionProvider,
            decisionTimeout: nil
        )
        let request = preToolUse(token: token.value)

        async let response = server.handle(request)
        await decisionProvider.waitUntilStarted()
        await server.invalidateToken(token.value)
        let resolvedResponse = await response
        try? await Task.sleep(nanoseconds: 100_000_000)
        let record = await interactionStore.record(id: "tool-1")

        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: resolvedResponse), .deferDecision)
        XCTAssertNil(record?.resolution)
    }

    private func preToolUse(token: String?) -> ClaudeHookRequest {
        ClaudeHookRequest(
            bearerToken: token,
            hookName: "PreToolUse",
            conversationId: "conversation",
            payload: .object([
                "hook_event_name": .string("PreToolUse"),
                "session_id": .string("session-123"),
                "tool_use_id": .string("tool-1"),
                "tool_name": .string("Edit"),
                "tool_input": .object([:])
            ])
        )
    }
}

private struct SlowDecisionProvider: ClaudeHookDecisionProviding {
    let delayNanoseconds: UInt64

    func decision(for request: ClaudeHookRequest, interactionId: AgentInteractionID) async -> ClaudeHookDecision {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        return .allow()
    }
}

private actor HangingSignalingDecisionProvider: ClaudeHookDecisionProviding {
    private var isStarted = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []

    func decision(for request: ClaudeHookRequest, interactionId: AgentInteractionID) async -> ClaudeHookDecision {
        isStarted = true
        startContinuations.forEach { $0.resume() }
        startContinuations.removeAll()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return .allow()
    }

    func waitUntilStarted() async {
        guard !isStarted else {
            return
        }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }
}

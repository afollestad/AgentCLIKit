import XCTest

@testable import AgentCLIKit

final class ClaudeHookMainActorHandoffTests: XCTestCase {
    func testMainActorDecisionProviderRunsHandlerOnMainActor() async {
        let recorder = MainActorDecisionRecorder()
        let provider = MainActorClaudeHookDecisionProvider { request, interactionId in
            recorder.record(request: request, interactionId: interactionId)
            return .allow()
        }
        let request = ClaudeHookRequest(
            bearerToken: nil,
            hookName: "PreToolUse",
            conversationId: "conversation",
            payload: .object([:])
        )

        let decision = await Task.detached {
            await provider.decision(for: request, interactionId: "approval")
        }.value
        let captured = await recorder.captured

        XCTAssertEqual(decision, .allow())
        XCTAssertEqual(captured?.hookName, "PreToolUse")
        XCTAssertEqual(captured?.interactionId, "approval")
        XCTAssertTrue(captured?.wasMainThread == true)
    }

    func testMainActorFactoryCreatesDecisionProvider() async {
        let provider = MainActorClaudeHookDecisionProvider.mainActor { _, _ in .deny(reason: "Denied") }
        let request = ClaudeHookRequest(
            bearerToken: nil,
            hookName: "PreToolUse",
            conversationId: "conversation",
            payload: .object([:])
        )

        let decision = await provider.decision(for: request, interactionId: "approval")

        XCTAssertEqual(decision, .deny(reason: "Denied"))
    }
}

@MainActor
private final class MainActorDecisionRecorder {
    private(set) var captured: Capture?

    func record(request: ClaudeHookRequest, interactionId: AgentInteractionID) {
        captured = Capture(
            hookName: request.hookName,
            interactionId: interactionId,
            wasMainThread: Thread.isMainThread
        )
    }

    struct Capture: Sendable {
        let hookName: String
        let interactionId: AgentInteractionID
        let wasMainThread: Bool
    }
}

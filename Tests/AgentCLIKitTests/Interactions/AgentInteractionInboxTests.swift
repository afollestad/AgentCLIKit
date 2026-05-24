import XCTest

@testable import AgentCLIKit

final class AgentInteractionInboxTests: XCTestCase {
    func testPromptRequestDecodesOlderPayloadWithDefaults() throws {
        let data = Data("""
        {
          "id": "prompt",
          "conversationId": "conversation",
          "prompt": "Continue?",
          "defaultResponse": "yes"
        }
        """.utf8)

        let request = try JSONDecoder().decode(AgentPromptRequest.self, from: data)

        XCTAssertEqual(request.options, [])
        XCTAssertTrue(request.allowsCustomResponse)
    }

    func testPromptAnswerBuildsCustomResponseResolution() {
        let answer = AgentPromptAnswer(interactionId: "prompt", responseText: "Use the API", source: .customResponse)

        let resolution = answer.resolution()

        XCTAssertEqual(resolution.id, "prompt")
        XCTAssertEqual(resolution.outcome, .answered)
        XCTAssertEqual(resolution.responseText, "Use the API")
        XCTAssertEqual(resolution.metadata["prompt_answer_source"], .string("customResponse"))
    }

    func testApprovalPolicyStoreTracksProviderScopedSessionGrant() async {
        let store = InMemoryAgentApprovalPolicyStore()
        await store.save(AgentApprovalSelection(
            interactionId: "approval",
            providerId: .claude,
            outcome: .approved,
            grantKind: .session,
            operation: "Bash"
        ))

        let matching = await store.isApprovedForSession(providerId: .claude, operation: "Bash")
        let otherOperation = await store.isApprovedForSession(providerId: .claude, operation: "Write")

        XCTAssertTrue(matching)
        XCTAssertFalse(otherOperation)
    }

    func testInboxPublishesInitialAndUpdatedSnapshots() async {
        let inbox = InMemoryAgentInteractionInbox()
        let stream = await inbox.subscribe(conversationId: "conversation")
        var iterator = stream.makeAsyncIterator()
        let request = AgentPromptRequest(id: "prompt", conversationId: "conversation", prompt: "Continue?")

        let initial = await iterator.next()
        await inbox.publish(AgentInteractionRecord(
            id: "prompt",
            conversationId: "conversation",
            kind: .prompt,
            promptRequest: request
        ))
        let published = await iterator.next()
        await inbox.resolve(AgentInteractionResolution(id: "prompt", outcome: .answered, responseText: "yes"))
        let resolved = await iterator.next()

        XCTAssertEqual(initial, [])
        XCTAssertEqual(published, [.prompt(request)])
        XCTAssertEqual(resolved, [])
    }
}

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

    func testPromptOptionDecodesDescriptionAndLegacyDefaults() throws {
        let optionWithMetadataDescription = try JSONDecoder().decode(
            AgentPromptOption.self,
            from: Data("""
            {
              "id": "a",
              "label": "Option A",
              "responseText": "A",
              "metadata": {
                "description": "Use option A"
              }
            }
            """.utf8)
        )
        let legacyOption = try JSONDecoder().decode(
            AgentPromptOption.self,
            from: Data(#"{"id":"b","label":"Option B","responseText":"B"}"#.utf8)
        )

        XCTAssertEqual(optionWithMetadataDescription.description, "Use option A")
        XCTAssertEqual(legacyOption.description, nil)
        XCTAssertEqual(legacyOption.metadata, [:])
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

    func testInboxDoesNotReopenResolvedInteractionAfterLatePublish() async {
        let inbox = InMemoryAgentInteractionInbox()
        let stream = await inbox.subscribe(conversationId: "conversation")
        var iterator = stream.makeAsyncIterator()
        let request = AgentPromptRequest(id: "prompt", conversationId: "conversation", prompt: "Continue?")
        let record = AgentInteractionRecord(
            id: "prompt",
            conversationId: "conversation",
            kind: .prompt,
            promptRequest: request
        )

        _ = await iterator.next()
        await inbox.publish(record)
        _ = await iterator.next()
        await inbox.resolve(AgentInteractionResolution(id: "prompt", outcome: .answered, responseText: "yes"))
        let resolved = await iterator.next()
        await inbox.publish(record)
        let latePublish = await iterator.next()
        let pending = await inbox.pendingActions(conversationId: "conversation")

        XCTAssertEqual(resolved, [])
        XCTAssertEqual(latePublish, [])
        XCTAssertEqual(pending, [])
    }
}

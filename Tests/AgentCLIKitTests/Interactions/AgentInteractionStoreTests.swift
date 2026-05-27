import XCTest

@testable import AgentCLIKit

final class AgentInteractionStoreTests: XCTestCase {
    func testStoreTracksPendingAndResolvedInteractions() async {
        let date = Date(timeIntervalSince1970: 10)
        let store = InMemoryAgentInteractionStore()
        let request = AgentApprovalRequest(
            id: "approval",
            providerId: .claude,
            conversationId: "conversation",
            operation: "Write",
            reason: "Needs file access",
            input: .object(["path": .string("README.md")]),
            createdAt: date
        )
        let record = AgentInteractionRecord(
            id: "approval",
            conversationId: "conversation",
            kind: .approval,
            approvalRequest: request,
            updatedAt: date
        )

        await store.save(record)
        let pending = await store.pending(conversationId: "conversation")
        XCTAssertEqual(pending, [record])

        let resolution = AgentInteractionResolution(id: "approval", outcome: .approved)
        await store.resolve(resolution, updatedAt: date.addingTimeInterval(1))

        let resolved = await store.record(id: "approval")
        XCTAssertEqual(resolved?.resolution, resolution)
        let remaining = await store.pending(conversationId: "conversation")
        XCTAssertEqual(remaining, [])
    }

    func testStoreUsesLastDuplicateRecord() async {
        let first = AgentInteractionRecord(id: "approval", conversationId: "conversation", kind: .approval)
        let second = AgentInteractionRecord(id: "approval", conversationId: "conversation", kind: .prompt)
        let store = InMemoryAgentInteractionStore(records: [first, second])

        let record = await store.record(id: "approval")

        XCTAssertEqual(record, second)
    }

    func testApprovalRequestExposesPresentationAndSessionMetadata() throws {
        let request = AgentApprovalRequest(
            id: "approval",
            providerId: .claude,
            conversationId: "conversation",
            providerSessionId: "session",
            operation: "Bash",
            reason: "Needs approval",
            input: .object(["command": .string("git add README.md")])
        )

        XCTAssertEqual(request.conciseSummary, "git add README.md")
        XCTAssertEqual(request.supportedSessionApprovalScopes, [.exact, .group])
        XCTAssertEqual(request.sessionApprovalRequest?.sessionId, "session")
        XCTAssertEqual(
            request.sessionApprovalRequest?.sessionApprovalGrant(for: .group)?.matchValue,
            "git add"
        )
    }

    func testApprovalAndPromptRequestsDecodeLegacyPayloadsWithoutProviderSession() throws {
        let approval = AgentApprovalRequest(
            id: "approval",
            providerId: .claude,
            conversationId: "conversation",
            providerSessionId: "session",
            operation: "ExitPlanMode",
            reason: "Plan",
            input: .object(["plan": .string("# Plan")])
        )
        let prompt = AgentPromptRequest(
            id: "prompt",
            conversationId: "conversation",
            providerSessionId: "session",
            prompt: "Continue?"
        )

        let legacyApproval = try decodeLegacy(approval, removing: "providerSessionId", as: AgentApprovalRequest.self)
        let legacyPrompt = try decodeLegacy(prompt, removing: "providerSessionId", as: AgentPromptRequest.self)

        XCTAssertNil(legacyApproval.providerSessionId)
        XCTAssertEqual(legacyApproval.planMarkdown, "# Plan")
        XCTAssertNil(legacyPrompt.providerSessionId)
    }

    private func decodeLegacy<T: Codable>(_ value: T, removing key: String, as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: key)
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(type, from: legacyData)
    }
}

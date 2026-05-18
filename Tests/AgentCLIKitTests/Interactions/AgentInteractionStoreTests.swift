import XCTest

@testable import AgentCLIKit

final class AgentInteractionStoreTests: XCTestCase {
    func testStoreTracksPendingAndResolvedInteractions() async {
        let date = Date(timeIntervalSince1970: 10)
        let store = InMemoryAgentInteractionStore()
        let request = AgentApprovalRequest(
            id: "approval",
            providerId: "provider",
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
}

import XCTest

@testable import AgentCLIKit

final class AgentApprovalPolicyTests: XCTestCase {
    func testSessionApprovalRequestBuildsExactBashGrant() {
        let request = bashRequest(command: " git status ")

        XCTAssertEqual(request.supportedSessionApprovalScopes, [.exact, .group])
        XCTAssertEqual(
            request.sessionApprovalGrant(for: .exact),
            AgentSessionApprovalGrant(
                providerId: .claude,
                conversationId: "conversation",
                sessionId: "session",
                matchKind: .bashExact,
                matchValue: "git status"
            )
        )
    }

    func testSessionApprovalRequestBuildsConservativeBashGroupGrant() {
        let request = bashRequest(command: "swift test --filter ClaudeAdapterTests")

        XCTAssertEqual(
            request.sessionApprovalGrant(for: .group),
            AgentSessionApprovalGrant(
                providerId: .claude,
                conversationId: "conversation",
                sessionId: "session",
                matchKind: .bashCommandGroup,
                matchValue: "swift test"
            )
        )
    }

    func testBashGroupRejectsCompoundCommandAndLeadingOption() {
        XCTAssertEqual(bashRequest(command: "git add file.swift && git push").supportedSessionApprovalScopes, [.exact])
        XCTAssertEqual(bashRequest(command: "git -C repo status").supportedSessionApprovalScopes, [.exact])
    }

    func testSessionApprovalRequestBuildsExactFilePathGrant() {
        let request = AgentSessionApprovalRequest(
            providerId: .claude,
            conversationId: "conversation",
            sessionId: "session",
            toolName: "Edit",
            toolInput: .object(["file_path": .string("Sources/Auth.swift")])
        )

        XCTAssertEqual(request.supportedSessionApprovalScopes, [.exact])
        XCTAssertEqual(
            request.sessionApprovalGrant(for: .exact),
            AgentSessionApprovalGrant(
                providerId: .claude,
                conversationId: "conversation",
                sessionId: "session",
                matchKind: .filePathExact,
                matchValue: "Sources/Auth.swift"
            )
        )
    }

    func testInMemoryPolicyRecordsMatchesAndRemovesSessionApprovals() async throws {
        let store = InMemoryAgentApprovalPolicyStore()
        let request = bashRequest(command: "git add foo.swift")
        let grant = try XCTUnwrap(request.sessionApprovalGrant(for: .group))

        let first = await store.recordSessionApproval(grant)
        let second = await store.recordSessionApproval(grant)
        let matchesGroup = await store.allowsSessionApproval(bashRequest(command: "git add bar.swift"))

        await store.removeSessionApprovals(providerId: .claude, conversationId: "conversation", sessionId: "session")
        let matchesAfterRemoval = await store.allowsSessionApproval(bashRequest(command: "git add baz.swift"))

        XCTAssertEqual(first, AgentSessionApprovalRecordResult(isEffective: true, wasInserted: true))
        XCTAssertEqual(second, AgentSessionApprovalRecordResult(isEffective: true, wasInserted: false))
        XCTAssertTrue(matchesGroup)
        XCTAssertFalse(matchesAfterRemoval)
    }

    func testInMemoryPolicyDiscardsSingleSessionApproval() async throws {
        let store = InMemoryAgentApprovalPolicyStore()
        let request = bashRequest(command: "git status")
        let grant = try XCTUnwrap(request.sessionApprovalGrant(for: .exact))

        _ = await store.recordSessionApproval(grant)
        await store.discardSessionApproval(grant)
        let matches = await store.allowsSessionApproval(request)

        XCTAssertFalse(matches)
    }

    func testInMemoryPolicyKeepsOtherConversationApprovals() async {
        let store = InMemoryAgentApprovalPolicyStore()
        let otherGrant = AgentSessionApprovalGrant(
            providerId: .claude,
            conversationId: "other",
            sessionId: "session",
            matchKind: .bashExact,
            matchValue: "git status"
        )

        _ = await store.recordSessionApproval(otherGrant)
        await store.removeSessionApprovals(providerId: .claude, conversationId: "conversation", sessionId: "session")

        let matchesOther = await store.allowsSessionApproval(
            AgentSessionApprovalRequest(
                providerId: .claude,
                conversationId: "other",
                sessionId: "session",
                toolName: "Bash",
                toolInput: .object(["command": .string("git status")])
            )
        )

        XCTAssertTrue(matchesOther)
    }

    private func bashRequest(command: String) -> AgentSessionApprovalRequest {
        AgentSessionApprovalRequest(
            providerId: .claude,
            conversationId: "conversation",
            sessionId: "session",
            toolName: "Bash",
            toolInput: .object(["command": .string(command)])
        )
    }
}

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

        XCTAssertNil(request.recommendedSessionApprovalScope)
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
        XCTAssertEqual(bashRequest(command: "git -c alias.status=status status").supportedSessionApprovalScopes, [.exact])
    }

    func testBashApprovalRecommendationForReadOnlySQLite() {
        let first = bashRequest(command: "sqlite3 -readonly ~/Library/App.store \"SELECT 1\"")
        let second = bashRequest(command: "sqlite3 --readonly ~/Library/App.store \"SELECT 2\"")
        let writable = bashRequest(command: "sqlite3 ~/Library/App.store \"SELECT 1\"")

        XCTAssertEqual(first.supportedSessionApprovalScopes, [.exact, .group])
        XCTAssertEqual(first.recommendedSessionApprovalScope, .group)
        XCTAssertEqual(first.sessionApprovalGrant(for: .group)?.matchValue, "sqlite3 -readonly ~/Library/App.store")
        XCTAssertEqual(second.sessionApprovalGrant(for: .group)?.matchValue, "sqlite3 -readonly ~/Library/App.store")
        XCTAssertNil(writable.recommendedSessionApprovalScope)
    }

    func testBashApprovalRecommendationForReadOnlyGit() {
        let status = bashRequest(command: "git -C repo status --short")
        let branch = bashRequest(command: "git branch --list")
        let deleteBranch = bashRequest(command: "git branch -D feature")
        let add = bashRequest(command: "git add Sources/App.swift")

        XCTAssertEqual(status.supportedSessionApprovalScopes, [.exact, .group])
        XCTAssertEqual(status.recommendedSessionApprovalScope, .group)
        XCTAssertEqual(status.sessionApprovalGrant(for: .group)?.matchValue, "git status")
        XCTAssertEqual(branch.recommendedSessionApprovalScope, .group)
        XCTAssertEqual(branch.sessionApprovalGrant(for: .group)?.matchValue, "git branch")
        XCTAssertNil(deleteBranch.recommendedSessionApprovalScope)
        XCTAssertNil(add.recommendedSessionApprovalScope)
        XCTAssertEqual(add.sessionApprovalGrant(for: .group)?.matchValue, "git add")
    }

    func testBashApprovalRecommendationForSearchAndListCommands() {
        XCTAssertEqual(bashRequest(command: "rg token Sources").sessionApprovalGrant(for: .group)?.matchValue, "rg Sources")
        XCTAssertEqual(bashRequest(command: "grep -R token Tests").sessionApprovalGrant(for: .group)?.matchValue, "grep Tests")
        XCTAssertEqual(bashRequest(command: "ls -la Sources").sessionApprovalGrant(for: .group)?.matchValue, "ls Sources")
        XCTAssertEqual(bashRequest(command: "wc -l README.md").sessionApprovalGrant(for: .group)?.matchValue, "wc README.md")
        XCTAssertEqual(bashRequest(command: "pwd").sessionApprovalGrant(for: .group)?.matchValue, "pwd")

        XCTAssertEqual(bashRequest(command: "rg token Sources").recommendedSessionApprovalScope, .group)
        XCTAssertEqual(bashRequest(command: "grep -R token Tests").recommendedSessionApprovalScope, .group)
        XCTAssertEqual(bashRequest(command: "ls -la Sources").recommendedSessionApprovalScope, .group)
        XCTAssertEqual(bashRequest(command: "wc -l README.md").recommendedSessionApprovalScope, .group)
        XCTAssertEqual(bashRequest(command: "pwd").recommendedSessionApprovalScope, .group)
    }

    func testBashApprovalRecommendationRejectsExecutionConstructsAndBroadReaders() {
        XCTAssertNil(bashRequest(command: "rg token Sources | xargs rm").recommendedSessionApprovalScope)
        XCTAssertNil(bashRequest(command: "git status > out.txt").recommendedSessionApprovalScope)
        XCTAssertNil(bashRequest(command: "rg $(echo token) Sources").recommendedSessionApprovalScope)
        XCTAssertNil(bashRequest(command: "find . -delete").recommendedSessionApprovalScope)
        XCTAssertNil(bashRequest(command: "sed -i '' s/a/b/g file.txt").recommendedSessionApprovalScope)
        XCTAssertNil(bashRequest(command: "cat README.md").recommendedSessionApprovalScope)
        XCTAssertNil(bashRequest(command: "rg \"unterminated Sources").recommendedSessionApprovalScope)
    }

    func testBashApprovalIdentityStripsUnquotedRTKWrapper() {
        let wrapped = bashRequest(command: "rtk git log --oneline")
        let direct = bashRequest(command: "git log --oneline")
        let quoted = bashRequest(command: "\"rtk\" git log --oneline")

        XCTAssertEqual(wrapped.sessionApprovalGrant(for: .exact)?.matchValue, direct.sessionApprovalGrant(for: .exact)?.matchValue)
        XCTAssertEqual(wrapped.sessionApprovalGrant(for: .group)?.matchValue, direct.sessionApprovalGrant(for: .group)?.matchValue)
        XCTAssertEqual(wrapped.recommendedSessionApprovalScope, .group)
        XCTAssertNotEqual(quoted.sessionApprovalGrant(for: .exact)?.matchValue, direct.sessionApprovalGrant(for: .exact)?.matchValue)
        XCTAssertNil(quoted.recommendedSessionApprovalScope)
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

    func testSessionApprovalRequestBuildsExactNativeReadOnlyPathGrants() {
        let read = sessionApprovalRequest(
            toolName: "Read",
            toolInput: .object(["file_path": .string("/tmp/project/README.md")])
        )
        let list = sessionApprovalRequest(
            toolName: "LS",
            toolInput: .object(["path": .string("/tmp/project/Sources")])
        )
        let notebookRead = sessionApprovalRequest(
            toolName: "NotebookRead",
            toolInput: .object(["notebook_path": .string("/tmp/project/Analysis.ipynb")])
        )

        XCTAssertEqual(read.supportedSessionApprovalScopes, [.exact])
        XCTAssertEqual(list.supportedSessionApprovalScopes, [.exact])
        XCTAssertEqual(notebookRead.supportedSessionApprovalScopes, [.exact])
        XCTAssertEqual(read.sessionApprovalGrant(for: .exact)?.matchValue, "/tmp/project/README.md")
        XCTAssertEqual(list.sessionApprovalGrant(for: .exact)?.matchValue, "/tmp/project/Sources")
        XCTAssertEqual(notebookRead.sessionApprovalGrant(for: .exact)?.matchValue, "/tmp/project/Analysis.ipynb")
        XCTAssertEqual(read.sessionApprovalGrant(for: .exact)?.matchKind, .filePathExact)
        XCTAssertEqual(list.sessionApprovalGrant(for: .exact)?.matchKind, .filePathExact)
        XCTAssertEqual(notebookRead.sessionApprovalGrant(for: .exact)?.matchKind, .filePathExact)
    }

    func testSessionApprovalRequestDoesNotBuildGrepOrGlobGrants() {
        let grep = sessionApprovalRequest(
            toolName: "Grep",
            toolInput: .object(["pattern": .string("token"), "path": .string("/tmp/project")])
        )
        let glob = sessionApprovalRequest(
            toolName: "Glob",
            toolInput: .object(["pattern": .string("/tmp/project/**/*.swift")])
        )

        XCTAssertEqual(grep.supportedSessionApprovalScopes, [])
        XCTAssertEqual(glob.supportedSessionApprovalScopes, [])
        XCTAssertNil(grep.sessionApprovalGrant(for: .exact))
        XCTAssertNil(glob.sessionApprovalGrant(for: .exact))
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

    func testAgentApprovalRequestForwardsRecommendedSessionApprovalScope() {
        let request = AgentApprovalRequest(
            id: "approval",
            providerId: .claude,
            conversationId: "conversation",
            providerSessionId: "session",
            operation: "Bash",
            reason: "Approve Bash command",
            input: .object(["command": .string("git log --oneline")])
        )

        XCTAssertEqual(request.recommendedSessionApprovalScope, .group)
    }

    private func bashRequest(command: String) -> AgentSessionApprovalRequest {
        sessionApprovalRequest(
            toolName: "Bash",
            toolInput: .object(["command": .string(command)])
        )
    }

    private func sessionApprovalRequest(toolName: String, toolInput: JSONValue) -> AgentSessionApprovalRequest {
        AgentSessionApprovalRequest(
            providerId: .claude,
            conversationId: "conversation",
            sessionId: "session",
            toolName: toolName,
            toolInput: toolInput
        )
    }
}

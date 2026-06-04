import Foundation
import XCTest

@testable import AgentCLIKit

final class ClaudeHookCoordinatorTests: XCTestCase {
    func testCoordinatorPreparesPerLaunchSettingsAndInvalidatesToken() async throws {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)
        let supportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let coordinator = ClaudeHookCoordinator(
            tokenStore: tokenStore,
            server: server,
            supportDirectory: supportDirectory,
            makeListener: { _, _ in StubHookTransport(port: 4567) }
        )
        let processToken = UUID()

        let launch = try await coordinator.prepareLaunch(conversationId: "conversation", processToken: processToken)
        let settingsData = try Data(contentsOf: launch.settingsFileURL)
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: settingsData) as? [String: Any])

        XCTAssertEqual(launch.arguments, ["--settings", launch.settingsFileURL.path])
        XCTAssertEqual(launch.environment["AGENTCLIKIT_CLAUDE_HOOK_TOKEN"], launch.token)
        let issuedToken = await tokenStore.token(for: launch.token)
        XCTAssertEqual(issuedToken?.expiresAt, .distantFuture)
        let isValid = await tokenStore.validate(launch.token)
        XCTAssertTrue(isValid)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["PreToolUse"])
        XCTAssertNotNil(hooks["PreCompact"])
        XCTAssertNotNil(hooks["PostCompact"])

        await coordinator.invalidate(processToken: processToken)

        let isInvalidated = await tokenStore.validate(launch.token)
        XCTAssertFalse(isInvalidated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: launch.settingsFileURL.path))
    }

    func testCoordinatorShutdownRemovesActiveLaunchSettingsAndInvalidatesTokens() async throws {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)
        let supportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let coordinator = ClaudeHookCoordinator(
            tokenStore: tokenStore,
            server: server,
            supportDirectory: supportDirectory,
            makeListener: { _, _ in StubHookTransport(port: 4567) }
        )

        let first = try await coordinator.prepareLaunch(conversationId: "first", processToken: UUID())
        let second = try await coordinator.prepareLaunch(conversationId: "second", processToken: UUID())

        await coordinator.shutdown()

        let isFirstTokenValid = await tokenStore.validate(first.token)
        let isSecondTokenValid = await tokenStore.validate(second.token)

        XCTAssertFalse(isFirstTokenValid)
        XCTAssertFalse(isSecondTokenValid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.settingsFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.settingsFileURL.path))
    }

    func testCoordinatorSeedsLaunchPermissionModeForHookDecisions() async throws {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)
        let supportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let coordinator = ClaudeHookCoordinator(
            tokenStore: tokenStore,
            server: server,
            supportDirectory: supportDirectory,
            makeListener: { _, _ in StubHookTransport(port: 4567) }
        )

        let launch = try await coordinator.prepareLaunch(
            conversationId: "conversation",
            processToken: UUID(),
            permissionMode: "acceptEdits"
        )
        let edit = await server.handle(preToolUse(token: launch.token, toolName: "Edit"))
        let bash = await server.handle(preToolUse(token: launch.token, toolName: "Bash"))
        let pending = await interactionStore.pending(conversationId: "conversation")

        XCTAssertEqual(edit, .noDecision)
        XCTAssertEqual(ClaudeHookResponseMapper.decision(from: bash), .deferDecision)
        XCTAssertEqual(pending.first?.approvalRequest?.operation, "Bash")
    }

    func testCoordinatorClearsStaleLaunchPermissionMode() async throws {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)
        let supportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let coordinator = ClaudeHookCoordinator(
            tokenStore: tokenStore,
            server: server,
            supportDirectory: supportDirectory,
            makeListener: { _, _ in StubHookTransport(port: 4567) }
        )

        _ = try await coordinator.prepareLaunch(
            conversationId: "conversation",
            processToken: UUID(),
            permissionMode: "plan"
        )
        let launch = try await coordinator.prepareLaunch(
            conversationId: "conversation",
            processToken: UUID(),
            permissionMode: nil
        )
        let response = await server.handle(preToolUse(token: launch.token, toolName: "ExitPlanMode"))
        let pending = await interactionStore.pending(conversationId: "conversation")

        XCTAssertEqual(response, .noDecision)
        XCTAssertEqual(pending, [])
    }

    func testCoordinatorRegistersCompactHooksWhenApprovalHooksAreDisabled() async throws {
        let tokenStore = AgentHookTokenStore(now: { Date(timeIntervalSince1970: 10) })
        let interactionStore = InMemoryAgentInteractionStore()
        let server = ClaudeHookServer(tokenStore: tokenStore, interactionStore: interactionStore)
        let supportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let coordinator = ClaudeHookCoordinator(
            tokenStore: tokenStore,
            server: server,
            supportDirectory: supportDirectory,
            makeListener: { _, _ in StubHookTransport(port: 4567) }
        )
        let processToken = UUID()

        let launch = try await coordinator.prepareLaunch(
            conversationId: "conversation",
            processToken: processToken,
            permissionMode: "auto"
        )
        let settingsData = try Data(contentsOf: launch.settingsFileURL)
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: settingsData) as? [String: Any])
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let preCompact = try XCTUnwrap((hooks["PreCompact"] as? [[String: Any]])?.first)
        let preCompactTransport = try XCTUnwrap((preCompact["hooks"] as? [[String: Any]])?.first)
        let preCompactURLString = try XCTUnwrap(preCompactTransport["url"] as? String)
        let preCompactURL = try XCTUnwrap(URLComponents(string: preCompactURLString))
        let query = Dictionary(uniqueKeysWithValues: (preCompactURL.queryItems ?? []).compactMap { item -> (String, String)? in
            guard let value = item.value else {
                return nil
            }
            return (item.name, value)
        })

        XCTAssertNil(hooks["PreToolUse"])
        XCTAssertNotNil(hooks["PostCompact"])
        XCTAssertEqual(preCompact["matcher"] as? String, ClaudeHookPolicy.compactMatcher)
        XCTAssertEqual(preCompactURL.path, "/claude/hooks/pre-compact")
        XCTAssertEqual(query["conversation_id"], "conversation")
        XCTAssertEqual(query["process_token"], processToken.uuidString)
    }
}

private func preToolUse(
    token: String?,
    toolName: String,
    toolUseId: String = "tool-1",
    sessionId: String = "session-123"
) -> ClaudeHookRequest {
    ClaudeHookRequest(
        bearerToken: token,
        hookName: "PreToolUse",
        conversationId: "conversation",
        payload: .object([
            "hook_event_name": .string("PreToolUse"),
            "session_id": .string(sessionId),
            "tool_name": .string(toolName),
            "tool_input": .object([:]),
            "tool_use_id": .string(toolUseId)
        ])
    )
}

private struct StubHookTransport: ClaudeHookListeningTransport {
    let port: Int

    func start() async throws -> Int {
        port
    }

    func stop() async {}
}

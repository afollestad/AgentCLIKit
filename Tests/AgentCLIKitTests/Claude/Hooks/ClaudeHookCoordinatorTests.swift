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
        XCTAssertNotNil(settings["hooks"])

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
}

private struct StubHookTransport: ClaudeHookListeningTransport {
    let port: Int

    func start() async throws -> Int {
        port
    }

    func stop() async {}
}

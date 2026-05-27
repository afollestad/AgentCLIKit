import Foundation
import XCTest

@testable import AgentCLIKit

final class DefaultAgentRuntimeSeamTests: XCTestCase {
    func testRuntimeUsesInjectedClockForProviderSessionRecords() async throws {
        let sessionStore = InMemoryAgentSessionStore()
        let fixedDate = Date(timeIntervalSince1970: 1_234)
        let runtime = DefaultAgentRuntime(
            adapters: [SessionReportingProviderAdapter(command: shell("printf 'session:provider-session\\n'"))],
            sessionStore: sessionStore,
            now: { fixedDate }
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        _ = await waitForExit(runtime: runtime, conversationId: conversationId)
        let persisted = try await sessionStore.record(conversationId: conversationId, providerId: .claude)

        XCTAssertEqual(persisted?.createdAt, fixedDate)
        XCTAssertEqual(persisted?.updatedAt, fixedDate)
    }

    func testRuntimeUsesInjectedProcessFactory() async throws {
        let probe = ProcessFactoryProbe()
        let runtime = DefaultAgentRuntime(
            adapters: [FakeProviderAdapter(command: shell("printf 'message:factory\\n'"))],
            processFactory: { launch, config in
                probe.record(launch: launch, config: config)
                return DefaultAgentRuntime.defaultProcessFactory(launch: launch, config: config)
            }
        )
        let conversationId: AgentConversationID = "conversation"

        try await runtime.spawn(conversationId: conversationId, config: spawnConfig())
        let status = await waitForExit(runtime: runtime, conversationId: conversationId)

        XCTAssertEqual(status?.state, .exited)
        XCTAssertEqual(probe.launches.map(\.executable), ["/bin/sh"])
        XCTAssertEqual(probe.launches.flatMap(\.arguments), ["-c", "printf 'message:factory\\n'"])
        XCTAssertEqual(probe.workingDirectories.map(\.path), [FileManager.default.temporaryDirectory.path])
    }
}

private final class ProcessFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var launches: [AgentLaunchConfiguration] = []
    private(set) var workingDirectories: [URL] = []

    func record(launch: AgentLaunchConfiguration, config: AgentSpawnConfig) {
        lock.withLock {
            launches.append(launch)
            workingDirectories.append(config.workingDirectory)
        }
    }
}

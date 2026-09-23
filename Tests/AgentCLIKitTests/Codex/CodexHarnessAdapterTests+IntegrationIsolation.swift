import Foundation
import XCTest

@testable import AgentCLIKit

/// Per-thread integration isolation on Codex's shared App Server.
extension CodexHarnessAdapterTests {
    func testCodexDefinitionSupportsBothIsolationOptions() {
        XCTAssertEqual(
            CodexHarnessDefinition.definition.capabilities.supportedIntegrationIsolation,
            [.nativeIntegrations, .shellNetwork]
        )
    }

    func testIsolatedStartSendsReadOnlySandboxAndMergesFeaturesWithFastMode() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexHarnessAdapter(configuration: configuration(
            transport: transport,
            featureSupportChecker: FixedCodexFeatureSupportChecker(supportsFastMode: true)
        ))

        _ = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                harnessId: .codex,
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                permissionMode: "never",
                speedMode: .fast,
                integrationIsolation: [.nativeIntegrations, .shellNetwork]
            ),
            resumedSession: nil
        )

        let requests = await transport.requestParams
        let params = try XCTUnwrap(requests["thread/start"]?.objectValue)
        XCTAssertEqual(params["sandbox"], .string("workspace-write"))
        XCTAssertEqual(params["approvalPolicy"], .string("never"))
        XCTAssertEqual(params["config"], .object([
            "features": .object([
                "fast_mode": .bool(true),
                "apps": .bool(false),
                "plugins": .bool(false)
            ]),
            "sandbox_workspace_write.network_access": .bool(false)
        ]))
    }

    func testEachIsolationOptionAppliesIndependently() async throws {
        let integrationsTransport = FakeCodexAppServerTransport(threadIds: ["thread-a"])
        _ = try await CodexHarnessAdapter(configuration: configuration(transport: integrationsTransport))
            .makeLaunchConfiguration(
                spawnConfig: AgentSpawnConfig(
                    harnessId: .codex,
                    workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                    integrationIsolation: .nativeIntegrations
                ),
                resumedSession: nil
            )
        let integrationsRequests = await integrationsTransport.requestParams
        let integrationsParams = try XCTUnwrap(integrationsRequests["thread/start"]?.objectValue)
        XCTAssertNil(integrationsParams["sandbox"])
        XCTAssertEqual(integrationsParams["config"], .object([
            "features": .object(["apps": .bool(false), "plugins": .bool(false)])
        ]))

        let networkTransport = FakeCodexAppServerTransport(threadIds: ["thread-b"])
        _ = try await CodexHarnessAdapter(configuration: configuration(transport: networkTransport))
            .makeLaunchConfiguration(
                spawnConfig: AgentSpawnConfig(
                    harnessId: .codex,
                    workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                    integrationIsolation: .shellNetwork
                ),
                resumedSession: nil
            )
        let networkRequests = await networkTransport.requestParams
        let networkParams = try XCTUnwrap(networkRequests["thread/start"]?.objectValue)
        XCTAssertEqual(networkParams["sandbox"], .string("workspace-write"))
        XCTAssertEqual(networkParams["config"], .object(["sandbox_workspace_write.network_access": .bool(false)]))
    }

    func testUnisolatedStartLeavesSandboxAndFeaturesToUserConfig() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        _ = try await CodexHarnessAdapter(configuration: configuration(transport: transport)).makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(harnessId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project")),
            resumedSession: nil
        )

        let requests = await transport.requestParams
        let params = try XCTUnwrap(requests["thread/start"]?.objectValue)
        XCTAssertNil(params["sandbox"])
        XCTAssertNil(params["config"])
    }

    /// A loaded thread ignores `thread/resume` config, so an isolated relaunch must fork to take effect.
    func testIsolatedResumeForksSoOverridesApply() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-forked"], threadForkedFromIds: ["thread-existing"])
        let adapter = CodexHarnessAdapter(configuration: configuration(transport: transport))
        let resumedSession = AgentSessionRecord(
            conversationId: "conversation",
            harnessId: .codex,
            harnessSessionId: "thread-existing",
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            generation: 1
        )

        let launch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                harnessId: .codex,
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                integrationIsolation: [.nativeIntegrations, .shellNetwork]
            ),
            resumedSession: resumedSession
        )

        let requestMethods = await transport.requestMethods
        let requests = await transport.requestParams
        let params = try XCTUnwrap(requests["thread/fork"]?.objectValue)
        XCTAssertEqual(requestMethods, ["initialize", "thread/fork"])
        XCTAssertEqual(launch.sessionContinuity, .forked)
        XCTAssertEqual(params["threadId"], .string("thread-existing"))
        XCTAssertEqual(params["sandbox"], .string("workspace-write"))
        XCTAssertEqual(params["config"], .object([
            "features": .object(["apps": .bool(false), "plugins": .bool(false)]),
            "sandbox_workspace_write.network_access": .bool(false)
        ]))
    }

    func testIsolationRoundTripsAndOlderSpawnConfigsDecodeUnisolated() throws {
        let isolated = AgentSpawnConfig(
            harnessId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            integrationIsolation: [.nativeIntegrations, .shellNetwork]
        )
        let decoded = try JSONDecoder().decode(AgentSpawnConfig.self, from: JSONEncoder().encode(isolated))
        XCTAssertEqual(decoded.integrationIsolation, [.nativeIntegrations, .shellNetwork])

        let legacy = Data(#"{"providerId":"codex","workingDirectory":"file:///tmp/project"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AgentSpawnConfig.self, from: legacy).integrationIsolation, [])
        let legacyCapabilities = try JSONDecoder().decode(AgentHarnessCapabilities.self, from: Data("{}".utf8))
        XCTAssertEqual(legacyCapabilities.supportedIntegrationIsolation, [])
    }
}

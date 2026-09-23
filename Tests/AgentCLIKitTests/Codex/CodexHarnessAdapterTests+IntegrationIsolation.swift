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
        let adapter = CodexHarnessAdapter(configuration: try isolationConfiguration(
            transport: transport,
            featureSupportChecker: FixedCodexFeatureSupportChecker(supportsFastMode: true, supportsGoalMode: false)
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
        _ = try await CodexHarnessAdapter(configuration: try isolationConfiguration(transport: integrationsTransport))
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
        _ = try await CodexHarnessAdapter(configuration: try isolationConfiguration(transport: networkTransport))
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
        _ = try await CodexHarnessAdapter(configuration: try isolationConfiguration(transport: transport)).makeLaunchConfiguration(
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
        let adapter = CodexHarnessAdapter(configuration: try isolationConfiguration(transport: transport))
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

    /// User and trusted-project servers are what a user may have pointed at GitHub; each is disabled by its own
    /// dotted leaf so the host-tool entry beside them survives.
    func testNativeIsolationWithholdsUserAndTrustedProjectMCPServers() async throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("isolation-project-\(UUID().uuidString)")
        let home = try makeCodexHome(config: """
        [mcp_servers.github]
        command = "github-mcp"

        [mcp_servers.docs]
        url = "https://example.com/mcp"

        [mcp_servers."has.dot"]
        command = "dotted-mcp"

        [projects."\(AgentPathHelpers.canonicalPath(project))"]
        trust_level = "trusted"
        """)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try "[mcp_servers.project_tool]\ncommand = \"project-mcp\"\n".write(
            to: project.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8
        )
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-a", "thread-b"])
        let adapter = CodexHarnessAdapter(configuration: try isolationConfiguration(transport: transport, home: home))

        _ = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(harnessId: .codex, workingDirectory: project, integrationIsolation: .nativeIntegrations),
            resumedSession: nil
        )
        let isolatedRequests = await transport.requestParams
        let isolated = try XCTUnwrap(isolatedRequests["thread/start"]?.objectValue?["config"]?.objectValue)
        XCTAssertEqual(isolated["mcp_servers.github.enabled"], .bool(false))
        XCTAssertEqual(isolated["mcp_servers.docs.enabled"], .bool(false))
        XCTAssertEqual(isolated["mcp_servers.project_tool.enabled"], .bool(false))
        // A dotted name cannot be addressed as an override, and a malformed key could fail the whole launch.
        XCTAssertFalse(isolated.keys.contains { $0.contains("has.dot") })

        _ = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(harnessId: .codex, workingDirectory: project),
            resumedSession: nil
        )
        let unisolatedRequests = await transport.requestParams
        XCTAssertNil(unisolatedRequests["thread/start"]?.objectValue?["config"])
    }

    func testAnUntrustedProjectsMCPServersAreNotRead() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("untrusted-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try "[mcp_servers.project_tool]\ncommand = \"project-mcp\"\n".write(
            to: project.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8
        )
        let home = try makeCodexHome(config: "[mcp_servers.github]\ncommand = \"github-mcp\"\n")

        XCTAssertEqual(
            CodexConfigStore.configuredMCPServerNames(codexHomeDirectoryURL: home, workingDirectory: project),
            ["github"]
        )
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

    private func makeCodexHome(config: String = "") throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try config.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        return home
    }

    /// An empty Codex home by default, so the machine's own `~/.codex` servers never reach an assertion.
    private func isolationConfiguration(
        transport: FakeCodexAppServerTransport,
        home: URL? = nil,
        featureSupportChecker: any CodexFeatureSupportChecking = FixedCodexFeatureSupportChecker(
            supportsFastMode: false, supportsGoalMode: false
        )
    ) throws -> CodexHarnessAdapter.Configuration {
        CodexHarnessAdapter.Configuration(
            codexHomeDirectory: try home ?? makeCodexHome(),
            requestTimeout: 0.1,
            probeTimeout: 0.1,
            featureSupportChecker: featureSupportChecker,
            makeTransport: { _ in transport },
            executableResolver: RecordingExecutableResolver(path: nil)
        )
    }
}

import XCTest

@testable import AgentCLIKit

/// OpenCode runs one server per conversation, so native isolation is that server's own `--pure` flag and config layer.
extension OpenCodeRuntimeCompatibilityTests {
    func testNativeIsolationDisablesEveryConfiguredMCPServerAndExternalPlugins() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let probe = ShellCommand(executable: "/test/opencode", arguments: ["debug", "config"], workingDirectory: directory)
        let resolved = #"{"mcp":{"github":{"type":"local","command":["gh-mcp"]},"agentclikit_host":{"type":"remote"}}}"#
        let runner = FakeShellRunner(results: [probe: .success(ShellCommandResult(exitCode: 0, stdout: resolved, stderr: ""))])
        let client = OpenCodeClient(configuration: .init(executablePath: "/test/opencode", oneShotShellRunner: runner))
        let endpoint = AgentHostToolEndpoint(
            serverName: "agentclikit_host", url: try XCTUnwrap(URL(string: "http://127.0.0.1:43210/mcp/a")),
            bearerToken: "token", enabledToolNames: ["host_tool"]
        )

        let isolated = try await client.serverConfiguration(
            config: AgentSpawnConfig(harnessId: .opencode, workingDirectory: directory, integrationIsolation: .nativeIntegrations),
            endpoint: endpoint
        )
        let content = try XCTUnwrap(isolated.environment["OPENCODE_CONFIG_CONTENT"])
        let document = try OpenCodeJSONCDocument(data: Data(content.utf8))
        XCTAssertTrue(isolated.excludesExternalPlugins)
        XCTAssertEqual(document.root["mcp"]?[oc: "github"]?[oc: "enabled"], .bool(false))
        XCTAssertEqual(document.root["mcp"]?[oc: "agentclikit_host"]?[oc: "enabled"], .bool(true))

        let plain = try await client.serverConfiguration(
            config: AgentSpawnConfig(harnessId: .opencode, workingDirectory: directory), endpoint: endpoint
        )
        let plainDocument = try OpenCodeJSONCDocument(data: Data(try XCTUnwrap(plain.environment["OPENCODE_CONFIG_CONTENT"]).utf8))
        XCTAssertFalse(plain.excludesExternalPlugins)
        XCTAssertNil(plainDocument.root["mcp"]?[oc: "github"])
        let probes = await runner.commands()
        XCTAssertEqual(probes.count, 1, "Only an isolated launch pays for the config probe.")
        await client.shutdown()
    }

    func testAFailedProbeStillExcludesPluginsAndLaunches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = OpenCodeClient(configuration: .init(executablePath: "/test/opencode", oneShotShellRunner: FakeShellRunner()))

        let isolated = try await client.serverConfiguration(
            config: AgentSpawnConfig(harnessId: .opencode, workingDirectory: directory, integrationIsolation: .nativeIntegrations),
            endpoint: nil
        )

        XCTAssertTrue(isolated.excludesExternalPlugins)
        XCTAssertNil(isolated.environment["OPENCODE_CONFIG_CONTENT"])
        await client.shutdown()
    }
}

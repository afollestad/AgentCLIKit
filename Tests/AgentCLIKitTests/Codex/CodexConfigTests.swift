import Darwin
import XCTest

@testable import AgentCLIKit

final class CodexConfigTests: XCTestCase {
    func testConfigStoreTrustsProjectAndPreservesUnrelatedSettings() async throws {
        let fileURL = temporaryDirectory().appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        model = "gpt-5.4"

        [tools]
        web_search = "cached"
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = CodexConfigStore(fileURL: fileURL)
        let projectURL = temporaryDirectory().appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        XCTAssertEqual(store.cachedProjectTrustStatus(projectURL), .notTrusted)
        try await store.trustProject(projectURL)

        let config = try await store.load()
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let projectPath = AgentPathHelpers.canonicalPath(projectURL)
        let trustStatus = try await store.projectTrustStatus(projectURL)

        XCTAssertEqual(config.trustedProjects, [projectPath])
        XCTAssertEqual(trustStatus, .trusted)
        XCTAssertEqual(store.cachedProjectTrustStatus(projectURL), .trusted)
        XCTAssertTrue(text.contains("model = \"gpt-5.4\""))
        XCTAssertTrue(text.contains("[tools]"))
        XCTAssertTrue(text.contains("[projects.\"\(projectPath)\"]"))
        XCTAssertTrue(text.contains("trust_level = \"trusted\""))
    }

    func testConfigStoreTracksUntrustedProjectsAndSnapshots() async throws {
        let fileURL = temporaryDirectory().appendingPathComponent("config.toml")
        let projectURL = temporaryDirectory().appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let projectPath = AgentPathHelpers.canonicalPath(projectURL)
        try """
        [projects."\(projectPath)"]
        trust_level = "untrusted"
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = CodexConfigStore(fileURL: fileURL)

        let snapshot = try await store.currentSnapshot()
        let config = try await store.load()

        XCTAssertEqual(snapshot.revision, 0)
        XCTAssertTrue(snapshot.isUntrustedProject(path: projectPath))
        XCTAssertEqual(config.untrustedProjects, [projectPath])
        let trustStatus = try await store.projectTrustStatus(projectURL)
        XCTAssertEqual(trustStatus, .notTrusted)
    }

    func testConfigStoreHandlesDuplicateTOMLKeysWithoutCrashing() async throws {
        let fileURL = temporaryDirectory().appendingPathComponent("config.toml")
        let projectURL = temporaryDirectory().appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let projectPath = AgentPathHelpers.canonicalPath(projectURL)
        try """
        [projects."\(projectPath)"]
        trust_level = "untrusted"

        [projects."\(projectPath)"]
        trust_level = "trusted"

        [mcp_servers.server]
        command = "first"
        command = "second"
        env = { "A" = "old", "A" = "new" }
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = CodexConfigStore(fileURL: fileURL)

        let config = try await store.load()
        let mcpServers = try await store.readMCPServers()

        XCTAssertEqual(config.trustedProjects, [projectPath])
        XCTAssertEqual(mcpServers["server"]?.command, "second")
        XCTAssertEqual(mcpServers["server"]?.env, ["A": "new"])
    }

    func testConfigStoreLoadsProjectConfigOnlyWhenTrusted() async throws {
        let codexHome = temporaryDirectory()
        let userConfigURL = codexHome.appendingPathComponent("config.toml")
        let projectURL = temporaryDirectory().appendingPathComponent("project", isDirectory: true)
        let projectConfigURL = CodexConfigStore.projectConfigFileURL(for: projectURL)
        try FileManager.default.createDirectory(at: projectConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [mcp_servers.project_docs]
        command = "npx"
        args = ["docs-mcp"]
        """.write(to: projectConfigURL, atomically: true, encoding: .utf8)
        let store = CodexConfigStore(fileURL: userConfigURL)

        let untrustedProjectConfig = try await store.loadTrustedProjectConfig(for: projectURL)
        try await store.trustProject(projectURL)
        let trustedProjectConfig = try await store.loadTrustedProjectConfig(for: projectURL)

        XCTAssertNil(untrustedProjectConfig)
        XCTAssertEqual(trustedProjectConfig?.mcpServers, [
            AgentMCPServer(id: "project_docs", name: "project_docs", command: "npx", arguments: ["docs-mcp"])
        ])
    }

    func testConfigStoreReadsAndWritesCodexNativeMCPServerMap() async throws {
        let fileURL = temporaryDirectory().appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        model = "gpt-5.4"

        [mcp_servers.old]
        command = "old"

        [profiles.review]
        model = "gpt-5.5"
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = CodexConfigStore(fileURL: fileURL)
        let servers = [
            "figma": CodexMCPServerConfig(
                url: "https://mcp.figma.com/mcp",
                bearerTokenEnvVar: "FIGMA_TOKEN",
                httpHeaders: ["X-Figma-Region": "us-east-1"],
                enabledTools: ["open"],
                defaultToolsApprovalMode: "prompt"
            ),
            "stdio": CodexMCPServerConfig(
                command: "node",
                args: ["server.js"],
                env: ["A": "B"],
                envVars: ["LOCAL_TOKEN"],
                startupTimeoutSec: 20,
                toolTimeoutSec: 45,
                enabled: false,
                required: true
            )
        ]

        try await store.writeMCPServers(servers)
        let reloaded = try await store.readMCPServers()
        let text = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertEqual(reloaded, servers)
        XCTAssertTrue(text.contains("model = \"gpt-5.4\""))
        XCTAssertTrue(text.contains("[profiles.review]"))
        XCTAssertFalse(text.contains("[mcp_servers.old]"))
        XCTAssertTrue(text.contains("[mcp_servers.\"figma\"]"))
        XCTAssertTrue(text.contains("bearer_token_env_var = \"FIGMA_TOKEN\""))
        XCTAssertTrue(text.contains("[mcp_servers.\"stdio\".env]"))
    }

    func testMCPBridgeRoundTripsGenericCodexConfigShape() throws {
        let bridge = CodexMCPBridge()
        let config = AgentMCPConfig(servers: [
            AgentMCPServer(
                id: "server",
                name: "Server",
                command: "node",
                arguments: ["server.js"],
                environment: ["A": "B"],
                isEnabled: false
            )
        ])

        let data = try bridge.encode(config)
        let decoded = try bridge.decode(data)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(decoded, AgentMCPConfig(servers: [
            AgentMCPServer(
                id: "server",
                name: "server",
                command: "node",
                arguments: ["server.js"],
                environment: ["A": "B"],
                isEnabled: false
            )
        ]))
        XCTAssertTrue(text.contains("[mcp_servers.\"server\"]"))
        XCTAssertTrue(text.contains("enabled = false"))
    }

    func testMCPBridgeDecodesInlineMapsAndSkipsHTTPOnlyServersInGenericConfig() throws {
        let data = Data("""
        [mcp_servers.context7]
        command = "npx"
        args = ["-y", "@upstash/context7-mcp"]
        env = { "A" = "B" }

        [mcp_servers.figma]
        url = "https://mcp.figma.com/mcp"
        http_headers = { "X-Figma-Region" = "us-east-1" }
        """.utf8)

        let decoded = try CodexMCPBridge().decode(data)

        XCTAssertEqual(decoded.servers, [
            AgentMCPServer(
                id: "context7",
                name: "context7",
                command: "npx",
                arguments: ["-y", "@upstash/context7-mcp"],
                environment: ["A": "B"]
            )
        ])
    }

    func testProviderSetupKeepsAuthReadinessSeparateFromProjectTrust() async throws {
        let codexHome = temporaryDirectory()
        let projectURL = temporaryDirectory().appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let setup = CodexProviderSetup(codexHomeDirectoryURL: codexHome)

        let authReadiness = setup.authReadiness()
        let trustStatus = try await setup.projectTrustStatus(for: projectURL)

        XCTAssertEqual(authReadiness.state, .missing)
        XCTAssertFalse(authReadiness.diagnostics.isEmpty)
        XCTAssertEqual(trustStatus, .notTrusted)
    }

    func testProviderSetupSeparatesCachedAndRefreshedAuthReadiness() async throws {
        let codexHome = temporaryDirectory()
        let authFileURL = codexHome.appendingPathComponent("auth.json")
        let setup = CodexProviderSetup(codexHomeDirectoryURL: codexHome)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try "{}".write(to: authFileURL, atomically: true, encoding: .utf8)
        let refreshedReadiness = await setup.setupReadiness()

        XCTAssertEqual(setup.cachedSetupReadiness(), .needsSetup)
        XCTAssertEqual(refreshedReadiness, .ready)
    }

    func testAuthProbeDetectsEnvironmentAndAuthJSONCredentialMaterial() throws {
        let authFileURL = temporaryDirectory().appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: authFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: authFileURL, atomically: true, encoding: .utf8)

        let fileReadiness = CodexAuthProbe(authFileURL: authFileURL, environment: [:]).readiness()
        let envReadiness = CodexAuthProbe(
            authFileURL: temporaryDirectory().appendingPathComponent("missing.json"),
            environment: ["CODEX_ACCESS_TOKEN": "token"]
        ).readiness()

        XCTAssertEqual(fileReadiness.state, .ready)
        XCTAssertEqual(fileReadiness.credentialSources, [.authJSON])
        XCTAssertEqual(envReadiness.state, .ready)
        XCTAssertEqual(envReadiness.credentialSources, [.environmentAccessToken])
    }

    func testConfigStoreRejectsInvalidUTF8() async throws {
        let fileURL = temporaryDirectory().appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF]).write(to: fileURL)
        let store = CodexConfigStore(fileURL: fileURL)

        do {
            _ = try await store.load()
            XCTFail("Expected invalid Codex config encoding.")
        } catch {
            XCTAssertEqual(error as? AgentCLIError, .invalidInput("Codex config must be UTF-8 TOML."))
        }
    }

    func testDefaultCodexHomeDirectoryRespectsEnvironmentOverride() {
        let oldValue = getenv("CODEX_HOME").map { String(cString: $0) }
        let overrideURL = temporaryDirectory()
        setenv("CODEX_HOME", overrideURL.path, 1)
        defer {
            if let oldValue {
                setenv("CODEX_HOME", oldValue, 1)
            } else {
                unsetenv("CODEX_HOME")
            }
        }

        XCTAssertEqual(CodexConfigStore.defaultCodexHomeDirectoryURL.path, overrideURL.path)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

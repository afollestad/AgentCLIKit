import Foundation
import XCTest

@testable import AgentCLIKit

final class ClaudeProviderAdapterHostToolTests: XCTestCase {
    func testContextLaunchUsesExactRootsMCPToolsEnvironmentAndResumeOrdering() async throws {
        let adapter = ClaudeProviderAdapter(
            executablePath: "/opt/homebrew/bin/claude",
            sessionFileExists: { _ in true }
        )
        let workingDirectory = URL(fileURLWithPath: "/tmp/project")
        let endpoint = Self.hostToolEndpoint

        let launch = try await adapter.makeLaunchConfiguration(context: AgentProviderLaunchContext(
            conversationId: "conversation",
            processToken: Self.processToken,
            spawnConfig: Self.resumedSpawnConfig(workingDirectory: workingDirectory),
            resumedSession: Self.resumedSession(workingDirectory: workingDirectory),
            hostToolEndpoint: endpoint
        ))

        let mcpConfigIndex = try XCTUnwrap(launch.arguments.firstIndex(of: "--mcp-config"))
        let mcpConfig = launch.arguments[mcpConfigIndex + 1]
        XCTAssertEqual(try Self.jsonObject(mcpConfig), Self.expectedMCPConfig())
        XCTAssertFalse(mcpConfig.contains(endpoint.bearerToken))
        XCTAssertEqual(launch.arguments, Self.expectedArguments(mcpConfig: mcpConfig))
        XCTAssertEqual(launch.environment, [
            "AGENTCLIKIT_HOST_MCP_TOKEN": "secret-token",
            "EXISTING": "value"
        ])
        XCTAssertEqual(launch.workingDirectory, workingDirectory)
        XCTAssertEqual(launch.sessionContinuity, .resumed)
    }

    func testReconfigureTreatsProviderSettingsAsLaunchOnly() async throws {
        let adapter = ClaudeProviderAdapter(executablePath: "/opt/homebrew/bin/claude")
        let currentConfig = AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: URL(fileURLWithPath: "/tmp/project")
        )
        let updatedConfig = AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            additionalWorkspaceRoots: [URL(fileURLWithPath: "/tmp/grant")],
            hostToolServer: AgentHostToolServerMetadata(name: "alveary_host"),
            hostTools: Self.hostTools
        )

        let idleResult = try await adapter.reconfigure(context: Self.reconfigureContext(
            currentConfig: currentConfig,
            newConfig: updatedConfig,
            isTurnActive: false
        ))
        let activeResult = try await adapter.reconfigure(context: Self.reconfigureContext(
            currentConfig: currentConfig,
            newConfig: updatedConfig,
            isTurnActive: true
        ))

        XCTAssertEqual(idleResult, .restartRequired)
        XCTAssertEqual(activeResult, .nextTurnRequired)
    }

    func testContextLaunchRejectsHostToolsWithoutRegisteredEndpoint() async {
        let adapter = ClaudeProviderAdapter(executablePath: "/opt/homebrew/bin/claude")
        let config = AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            hostToolServer: AgentHostToolServerMetadata(name: "alveary_host"),
            hostTools: Self.hostTools
        )

        do {
            _ = try await adapter.makeLaunchConfiguration(context: AgentProviderLaunchContext(
                conversationId: "conversation",
                processToken: Self.processToken,
                spawnConfig: config,
                resumedSession: nil
            ))
            XCTFail("Expected a missing host tool endpoint to fail launch.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error.code, .hostToolsUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDirectLaunchRejectsNonFileWorkspaceRoot() async {
        let adapter = ClaudeProviderAdapter(executablePath: "/opt/homebrew/bin/claude")
        let config = AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            additionalWorkspaceRoots: [URL(string: "https://example.com/grant") ?? URL(fileURLWithPath: "/invalid")]
        )

        do {
            _ = try await adapter.makeLaunchConfiguration(spawnConfig: config, resumedSession: nil)
            XCTFail("Expected a non-file workspace root to fail launch.")
        } catch {
            XCTAssertEqual(error as? AgentCLIError, .invalidInput("Additional workspace roots must be absolute file URLs."))
        }
    }

    private static let processToken = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()

    private static let hostTools = [
        AgentHostToolDefinition(
            name: "list_scheduled_tasks",
            description: "Lists scheduled tasks.",
            inputSchema: .object(["type": .string("object")])
        ),
        AgentHostToolDefinition(
            name: "propose_scheduled_task",
            description: "Proposes a scheduled task change.",
            inputSchema: .object(["type": .string("object")])
        )
    ]

    private static let hostToolEndpoint = AgentHostToolEndpoint(
        serverName: "alveary_host",
        url: URL(string: "http://127.0.0.1:43123/opaque") ?? URL(fileURLWithPath: "/invalid"),
        bearerToken: "secret-token",
        enabledToolNames: hostTools.map(\.name)
    )

    private static func expectedMCPConfig() -> NSDictionary {
        [
            "mcpServers": [
                "alveary_host": [
                    "alwaysLoad": true,
                    "headers": [
                        "Authorization": "Bearer ${AGENTCLIKIT_HOST_MCP_TOKEN}"
                    ],
                    "type": "http",
                    "url": "http://127.0.0.1:43123/opaque"
                ]
            ]
        ] as NSDictionary
    }

    private static func resumedSpawnConfig(workingDirectory: URL) -> AgentSpawnConfig {
        AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: workingDirectory,
            arguments: ["--debug"],
            environment: [
                "AGENTCLIKIT_HOST_MCP_TOKEN": "stale-token",
                "EXISTING": "value"
            ],
            model: "sonnet",
            effort: "high",
            permissionMode: "acceptEdits",
            additionalWorkspaceRoots: [
                workingDirectory,
                URL(fileURLWithPath: "/tmp/grant-a"),
                URL(fileURLWithPath: "/tmp/grant-b")
            ],
            hostToolServer: AgentHostToolServerMetadata(name: "alveary_host"),
            hostTools: hostTools
        )
    }

    private static func resumedSession(workingDirectory: URL) -> AgentSessionRecord {
        AgentSessionRecord(
            conversationId: "conversation",
            providerId: .claude,
            providerSessionId: "session-id",
            workingDirectory: workingDirectory,
            generation: 1
        )
    }

    private static func expectedArguments(mcpConfig: String) -> [String] {
        [
            "-p",
            "--output-format",
            "stream-json",
            "--input-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-mode",
            "acceptEdits",
            "--add-dir",
            "/tmp/grant-a",
            "/tmp/grant-b",
            "--mcp-config",
            mcpConfig,
            "--allowedTools",
            "mcp__alveary_host__list_scheduled_tasks",
            "mcp__alveary_host__propose_scheduled_task",
            "--model",
            "sonnet",
            "--effort",
            "high",
            "--resume",
            "session-id",
            "--debug"
        ]
    }

    private static func reconfigureContext(
        currentConfig: AgentSpawnConfig,
        newConfig: AgentSpawnConfig,
        isTurnActive: Bool
    ) -> AgentProviderReconfigureContext {
        AgentProviderReconfigureContext(
            conversationId: "conversation",
            processToken: processToken,
            providerSessionId: "session-id",
            currentConfig: currentConfig,
            newConfig: newConfig,
            isTurnActive: isTurnActive
        )
    }

    private static func jsonObject(_ string: String) throws -> NSDictionary {
        let data = try XCTUnwrap(string.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }
}

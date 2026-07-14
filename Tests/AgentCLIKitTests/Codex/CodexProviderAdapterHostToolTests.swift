import Foundation
import XCTest

@testable import AgentCLIKit

final class CodexProviderAdapterHostToolTests: XCTestCase {
    func testStartIncludesWorkspaceRootsAndDottedHostMCPConfig() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-started"])
        let adapter = CodexProviderAdapter(configuration: Self.configuration(transport: transport))
        let spawnConfig = Self.spawnConfig(workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        let launch = try await adapter.makeLaunchConfiguration(context: Self.launchContext(
            spawnConfig: spawnConfig,
            resumedSession: nil
        ))

        let requestMethods = await transport.requestMethods
        let requestParams = await transport.requestParams
        let params = try XCTUnwrap(requestParams["thread/start"]?.objectValue)
        XCTAssertEqual(requestMethods, ["initialize", "thread/start"])
        XCTAssertEqual(launch.sessionContinuity, .fresh)
        XCTAssertEqual(launch.providerSessionId, "thread-started")
        XCTAssertEqual(params["cwd"], .string("/tmp/project"))
        XCTAssertEqual(params["ephemeral"], .bool(false))
        XCTAssertNil(params["threadId"])
        Self.assertHostLaunchSettings(params, workingDirectory: "/tmp/project")
    }

    func testResumeWithHostToolsForksToApplyWorkspaceRootsAndDottedMCPConfig() async throws {
        let workingDirectory = URL(fileURLWithPath: "/tmp/project")
        let transport = FakeCodexAppServerTransport(
            threadIds: ["thread-forked"],
            threadForkedFromIds: ["thread-existing"]
        )
        let adapter = CodexProviderAdapter(configuration: Self.configuration(transport: transport))
        let spawnConfig = Self.spawnConfig(workingDirectory: workingDirectory)
        let resumedSession = AgentSessionRecord(
            conversationId: "conversation",
            providerId: .codex,
            providerSessionId: "thread-existing",
            workingDirectory: workingDirectory,
            generation: 1
        )

        let launch = try await adapter.makeLaunchConfiguration(context: Self.launchContext(
            spawnConfig: spawnConfig,
            resumedSession: resumedSession
        ))

        let requestMethods = await transport.requestMethods
        let requestParams = await transport.requestParams
        let params = try XCTUnwrap(requestParams["thread/fork"]?.objectValue)
        XCTAssertEqual(requestMethods, ["initialize", "thread/fork"])
        XCTAssertEqual(launch.sessionContinuity, .forked)
        XCTAssertEqual(launch.providerSessionId, "thread-forked")
        XCTAssertEqual(params["cwd"], .string("/tmp/project"))
        XCTAssertEqual(params["threadId"], .string("thread-existing"))
        XCTAssertEqual(params["ephemeral"], .bool(false))
        Self.assertHostLaunchSettings(params, workingDirectory: "/tmp/project")
    }

    func testForkIncludesWorkspaceRootsAndDottedHostMCPConfig() async throws {
        let workingDirectory = URL(fileURLWithPath: "/tmp/worktree")
        let transport = FakeCodexAppServerTransport(
            threadIds: ["thread-forked"],
            threadForkedFromIds: ["thread-source"]
        )
        let adapter = CodexProviderAdapter(configuration: Self.configuration(transport: transport))
        let spawnConfig = Self.spawnConfig(
            workingDirectory: workingDirectory,
            sessionFork: AgentSessionForkRequest(
                sourceSessionId: "thread-source",
                sourceWorkingDirectory: URL(fileURLWithPath: "/tmp/source"),
                mode: .worktree
            )
        )

        let launch = try await adapter.makeLaunchConfiguration(context: Self.launchContext(
            spawnConfig: spawnConfig,
            resumedSession: nil
        ))

        let requestMethods = await transport.requestMethods
        let requestParams = await transport.requestParams
        let params = try XCTUnwrap(requestParams["thread/fork"]?.objectValue)
        XCTAssertEqual(requestMethods, ["initialize", "thread/fork"])
        XCTAssertEqual(launch.sessionContinuity, .forked)
        XCTAssertEqual(launch.providerSessionId, "thread-forked")
        XCTAssertEqual(params["cwd"], .string("/tmp/worktree"))
        XCTAssertEqual(params["threadId"], .string("thread-source"))
        XCTAssertEqual(params["ephemeral"], .bool(false))
        Self.assertHostLaunchSettings(params, workingDirectory: "/tmp/worktree")
    }

    func testReconfigureRequiresRelaunchForRootsHostToolsAndServerMetadata() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: Self.configuration(transport: transport))
        let currentConfig = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project")
        )

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: currentConfig, resumedSession: nil)
        let stream = await adapter.runtimeEvents(context: AgentProviderRuntimeContext(
            conversationId: "conversation",
            processToken: Self.processToken,
            providerSessionId: "thread-123",
            spawnConfig: currentConfig
        ))
        _ = stream
        try await Task.sleep(nanoseconds: 20_000_000)

        var idleResults: [AgentProviderReconfigureResult] = []
        for updatedConfig in Self.launchOnlyConfigs {
            idleResults.append(try await adapter.reconfigure(context: Self.reconfigureContext(
                currentConfig: currentConfig,
                newConfig: updatedConfig,
                isTurnActive: false
            )))
        }
        let activeResult = try await adapter.reconfigure(context: Self.reconfigureContext(
            currentConfig: currentConfig,
            newConfig: Self.launchOnlyConfigs[1],
            isTurnActive: true
        ))

        let requestMethods = await transport.requestMethods
        XCTAssertEqual(idleResults, [
            .restartRequired,
            .restartRequired,
            .restartRequired
        ])
        XCTAssertEqual(activeResult, .nextTurnRequired)
        XCTAssertEqual(requestMethods, ["initialize", "thread/start"])
        XCTAssertFalse(requestMethods.contains("thread/settings/update"))
    }

    func testLaunchWithoutAdditionalRootsOmitsRuntimeWorkspaceRoots() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-started"])
        let adapter = CodexProviderAdapter(configuration: Self.configuration(transport: transport))
        let config = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            hostToolServer: AgentHostToolServerMetadata(
                name: "alveary_host",
                instructions: "Use Alveary host tools for scheduled-task requests."
            )
        )

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: config, resumedSession: nil)

        let requestParams = await transport.requestParams
        let params = try XCTUnwrap(requestParams["thread/start"]?.objectValue)
        XCTAssertNil(params["runtimeWorkspaceRoots"])
        XCTAssertNil(params["developerInstructions"])
    }

    func testWorkingDirectorySentinelReplacesRuntimeWorkspaceRootsWithCwdOnly() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-started"])
        let adapter = CodexProviderAdapter(configuration: Self.configuration(transport: transport))
        let config = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            additionalWorkspaceRoots: [URL(fileURLWithPath: "/tmp/project")]
        )

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: config, resumedSession: nil)

        let requestParams = await transport.requestParams
        let params = try XCTUnwrap(requestParams["thread/start"]?.objectValue)
        XCTAssertEqual(params["runtimeWorkspaceRoots"], .array([.string("/tmp/project")]))
    }

    func testUnsupportedRuntimeWorkspaceRootsProduceTypedDiagnostic() async {
        let transport = FakeCodexAppServerTransport(
            threadIds: [],
            requestErrors: [
                "thread/start": .jsonRPCError(
                    method: "thread/start",
                    code: -32602,
                    message: "unknown field runtimeWorkspaceRoots"
                )
            ]
        )
        let adapter = CodexProviderAdapter(configuration: Self.configuration(transport: transport))
        let config = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            additionalWorkspaceRoots: [URL(fileURLWithPath: "/tmp/grant")]
        )

        do {
            _ = try await adapter.makeLaunchConfiguration(spawnConfig: config, resumedSession: nil)
            XCTFail("Expected unsupported runtime workspace roots to fail launch.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error.code, .unsupportedCapability)
            XCTAssertTrue(error.localizedDescription.contains("Codex 0.144.0"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRuntimeWorkspaceRootsRequireExperimentalAPI() async {
        let transport = FakeCodexAppServerTransport(threadIds: [])
        let adapter = CodexProviderAdapter(configuration: Self.configuration(
            transport: transport,
            experimentalAPIEnabled: false
        ))
        let config = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            additionalWorkspaceRoots: [URL(fileURLWithPath: "/tmp/grant")]
        )

        do {
            _ = try await adapter.makeLaunchConfiguration(spawnConfig: config, resumedSession: nil)
            XCTFail("Expected runtime workspace roots to require experimental APIs.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error.code, .unsupportedCapability)
            XCTAssertTrue(error.localizedDescription.contains("experimental APIs enabled"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let requestMethods = await transport.requestMethods
        XCTAssertEqual(requestMethods, [])
    }

    func testContextLaunchRejectsHostToolsWithoutRegisteredEndpoint() async {
        let transport = FakeCodexAppServerTransport(threadIds: [])
        let adapter = CodexProviderAdapter(configuration: Self.configuration(transport: transport))
        let config = AgentSpawnConfig(
            providerId: .codex,
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

    func testBootstrapErrorRedactsHostBearerToken() async {
        let transport = FakeCodexAppServerTransport(
            threadIds: [],
            requestErrors: [
                "thread/start": .jsonRPCError(
                    method: "thread/start",
                    code: -32000,
                    message: "Rejected Authorization: Bearer secret-token"
                )
            ]
        )
        let adapter = CodexProviderAdapter(configuration: Self.configuration(transport: transport))
        let config = Self.spawnConfig(workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        do {
            _ = try await adapter.makeLaunchConfiguration(context: Self.launchContext(
                spawnConfig: config,
                resumedSession: nil
            ))
            XCTFail("Expected the fake transport to reject thread startup.")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("secret-token"))
            XCTAssertTrue(error.localizedDescription.contains("<redacted>"))
        }
    }

    func testDirectLaunchRejectsNonFileWorkspaceRootBeforeStartingCodex() async {
        let transport = FakeCodexAppServerTransport(threadIds: [])
        let adapter = CodexProviderAdapter(configuration: Self.configuration(transport: transport))
        let config = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            additionalWorkspaceRoots: [URL(string: "https://example.com/grant") ?? URL(fileURLWithPath: "/invalid")]
        )

        do {
            _ = try await adapter.makeLaunchConfiguration(spawnConfig: config, resumedSession: nil)
            XCTFail("Expected a non-file workspace root to fail launch.")
        } catch {
            XCTAssertEqual(error as? AgentCLIError, .invalidInput("Additional workspace roots must be absolute file URLs."))
        }
        let requestMethods = await transport.requestMethods
        XCTAssertEqual(requestMethods, [])
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

    private static let launchOnlyConfigs = [
        AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            additionalWorkspaceRoots: [URL(fileURLWithPath: "/tmp/grant")]
        ),
        AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            hostTools: hostTools
        ),
        AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            hostToolServer: AgentHostToolServerMetadata(name: "alveary_host")
        )
    ]

    private static func spawnConfig(
        workingDirectory: URL,
        sessionFork: AgentSessionForkRequest? = nil
    ) -> AgentSpawnConfig {
        AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: workingDirectory,
            model: "model-a",
            effort: "high",
            permissionMode: "on-request",
            sessionFork: sessionFork,
            additionalWorkspaceRoots: [
                workingDirectory,
                URL(fileURLWithPath: "/tmp/grant-a"),
                URL(fileURLWithPath: "/tmp/grant-b")
            ],
            hostToolServer: AgentHostToolServerMetadata(
                name: "alveary_host",
                instructions: "Use Alveary host tools for scheduled-task requests."
            ),
            hostTools: hostTools
        )
    }

    private static func launchContext(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) -> AgentProviderLaunchContext {
        AgentProviderLaunchContext(
            conversationId: "conversation",
            processToken: processToken,
            spawnConfig: spawnConfig,
            resumedSession: resumedSession,
            hostToolEndpoint: hostToolEndpoint
        )
    }

    private static func reconfigureContext(
        currentConfig: AgentSpawnConfig,
        newConfig: AgentSpawnConfig,
        isTurnActive: Bool
    ) -> AgentProviderReconfigureContext {
        AgentProviderReconfigureContext(
            conversationId: "conversation",
            processToken: processToken,
            providerSessionId: "thread-123",
            currentConfig: currentConfig,
            newConfig: newConfig,
            isTurnActive: isTurnActive
        )
    }

    private static func configuration(
        transport: FakeCodexAppServerTransport,
        experimentalAPIEnabled: Bool = true
    ) -> CodexProviderAdapter.Configuration {
        CodexProviderAdapter.Configuration(
            experimentalAPIEnabled: experimentalAPIEnabled,
            requestTimeout: 0.1,
            probeTimeout: 0.1,
            featureSupportChecker: FixedCodexFeatureSupportChecker(supportsFastMode: false, supportsGoalMode: false),
            makeTransport: { _ in transport },
            executableResolver: RecordingExecutableResolver(path: nil)
        )
    }

    private static func assertHostLaunchSettings(
        _ params: [String: JSONValue],
        workingDirectory: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(params["model"], .string("model-a"), file: file, line: line)
        XCTAssertEqual(params["approvalPolicy"], .string("on-request"), file: file, line: line)
        XCTAssertEqual(
            params["developerInstructions"],
            .string("Use Alveary host tools for scheduled-task requests."),
            file: file,
            line: line
        )
        XCTAssertEqual(params["runtimeWorkspaceRoots"], .array([
            .string(workingDirectory),
            .string("/tmp/grant-a"),
            .string("/tmp/grant-b")
        ]), file: file, line: line)
        XCTAssertEqual(params["config"], .object([
            "model_reasoning_effort": .string("high"),
            "mcp_servers.alveary_host": .object([
                "url": .string("http://127.0.0.1:43123/opaque"),
                "http_headers": .object([
                    "Authorization": .string("Bearer secret-token")
                ]),
                "enabled": .bool(true),
                "required": .bool(false),
                "enabled_tools": .array([
                    .string("list_scheduled_tasks"),
                    .string("propose_scheduled_task")
                ]),
                "tools": .object([
                    "list_scheduled_tasks": .object(["approval_mode": .string("approve")]),
                    "propose_scheduled_task": .object(["approval_mode": .string("approve")])
                ])
            ])
        ]), file: file, line: line)
    }
}

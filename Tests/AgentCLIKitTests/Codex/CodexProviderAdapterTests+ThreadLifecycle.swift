import XCTest

@testable import AgentCLIKit

/// Session lifecycle and transport reuse without starting provider turns.
extension CodexProviderAdapterTests {
    func testBorrowedRouterCleansUpThroughTheRuntimeTransportAndKeepsItUsable() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123", "thread-456"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let router = AgentProviderSessionActionRouter(borrowing: AgentProviderAdapterSet(adapters: [adapter]))
        let config = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: config, resumedSession: nil)
        try await router.deleteSession(sessionRecord(providerId: .codex))
        _ = try await adapter.makeLaunchConfiguration(spawnConfig: config, resumedSession: nil)

        let requestMethods = await transport.requestMethods
        let shutdownCount = await transport.shutdownCount
        XCTAssertEqual(requestMethods, ["initialize", "thread/start", "thread/delete", "thread/start"])
        XCTAssertEqual(shutdownCount, 0)

        await adapter.shutdownProviderResources()
    }

    func testArchivesThreadWithoutRuntimeBootstrap() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: [])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))

        try await adapter.archiveSession(sessionRecord(providerId: .codex, workingDirectory: nil))

        let requestMethods = await transport.requestMethods
        let requestParams = await transport.requestParams

        XCTAssertEqual(requestMethods, ["initialize", "thread/archive"])
        XCTAssertEqual(requestParams["thread/archive"]?.objectValue?["threadId"], .string("thread-123"))
        XCTAssertFalse(requestMethods.contains("thread/start"))
        XCTAssertFalse(requestMethods.contains("thread/resume"))
    }

    func testUnarchivesThreadWithoutRuntimeBootstrap() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: [])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))

        try await adapter.unarchiveSession(sessionRecord(providerId: .codex, workingDirectory: nil))

        let requestMethods = await transport.requestMethods
        let requestParams = await transport.requestParams

        XCTAssertEqual(requestMethods, ["initialize", "thread/unarchive"])
        XCTAssertEqual(requestParams["thread/unarchive"]?.objectValue?["threadId"], .string("thread-123"))
        XCTAssertFalse(requestMethods.contains("thread/start"))
        XCTAssertFalse(requestMethods.contains("thread/resume"))
    }

    func testDeletesThreadWithoutRuntimeBootstrap() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: [])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))

        try await adapter.deleteSession(sessionRecord(providerId: .codex, workingDirectory: nil))

        let requestMethods = await transport.requestMethods
        let requestParams = await transport.requestParams

        XCTAssertEqual(requestMethods, ["initialize", "thread/delete"])
        XCTAssertEqual(requestParams["thread/delete"]?.objectValue?["threadId"], .string("thread-123"))
        XCTAssertFalse(requestMethods.contains("thread/start"))
        XCTAssertFalse(requestMethods.contains("thread/resume"))
    }

    func testArchivesSupersededThreadsAlongsideTheBoundThread() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: [])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))

        try await adapter.archiveSession(supersedingSessionRecord(supersededSessionIds: ["thread-001", "thread-002"]))

        let requestMethods = await transport.requestMethods
        let archivedThreadIds = await transport.requestParamValues(method: "thread/archive", key: "threadId")

        XCTAssertEqual(requestMethods, ["initialize", "thread/archive", "thread/archive", "thread/archive"])
        XCTAssertEqual(archivedThreadIds, [.string("thread-001"), .string("thread-002"), .string("thread-123")])
    }

    func testDeleteArchivesSupersededThreadsAndDeletesOnlyTheBoundThread() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: [])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))

        try await adapter.deleteSession(supersedingSessionRecord(supersededSessionIds: ["thread-001", "thread-002"]))

        let requestMethods = await transport.requestMethods
        let archivedThreadIds = await transport.requestParamValues(method: "thread/archive", key: "threadId")
        let deletedThreadIds = await transport.requestParamValues(method: "thread/delete", key: "threadId")

        XCTAssertEqual(requestMethods, ["initialize", "thread/archive", "thread/archive", "thread/delete"])
        XCTAssertEqual(archivedThreadIds, [.string("thread-001"), .string("thread-002")])
        XCTAssertEqual(deletedThreadIds, [.string("thread-123")])
    }

    func testUnarchiveRestoresOnlyTheBoundThread() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: [])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))

        try await adapter.unarchiveSession(supersedingSessionRecord(supersededSessionIds: ["thread-001", "thread-002"]))

        let requestMethods = await transport.requestMethods
        let unarchivedThreadIds = await transport.requestParamValues(method: "thread/unarchive", key: "threadId")

        XCTAssertEqual(requestMethods, ["initialize", "thread/unarchive"])
        XCTAssertEqual(unarchivedThreadIds, [.string("thread-123")])
    }

    func testArchiveThrowsForMismatchedProviderRecord() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: [])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))

        do {
            try await adapter.archiveSession(sessionRecord(providerId: .claude))
            XCTFail("Expected mismatched provider record to throw.")
        } catch let error as AgentCLIError {
            guard case let .invalidInput(message) = error else {
                XCTFail("Expected invalidInput, got \(error).")
                return
            }
            XCTAssertTrue(message.contains("claude"))
            XCTAssertTrue(message.contains("codex"))
        }

        let requestMethods = await transport.requestMethods

        XCTAssertEqual(requestMethods, [])
    }

    func testArchiveSurfacesJSONRPCFailure() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: [], failingMethods: ["thread/archive"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))

        do {
            try await adapter.archiveSession(sessionRecord(providerId: .codex))
            XCTFail("Expected JSON-RPC failure.")
        } catch let error as CodexAppServerError {
            guard case let .jsonRPCError(method, code, message) = error else {
                XCTFail("Expected JSON-RPC error, got \(error).")
                return
            }
            XCTAssertEqual(method, "thread/archive")
            XCTAssertEqual(code, -32000)
            XCTAssertEqual(message, "thread/archive failed.")
        }
    }

    func testThreadLifecycleActionsSucceedWhenRolloutIsAlreadyGone() async throws {
        let actions: [(method: String, perform: (CodexProviderAdapter, AgentSessionRecord) async throws -> Void)] = [
            ("thread/archive", { try await $0.archiveSession($1) }),
            ("thread/unarchive", { try await $0.unarchiveSession($1) }),
            ("thread/delete", { try await $0.deleteSession($1) })
        ]

        for action in actions {
            let transport = FakeCodexAppServerTransport(
                threadIds: [],
                requestErrors: [
                    action.method: .jsonRPCError(
                        method: action.method,
                        code: -32600,
                        message: "no rollout found for thread id thread-123"
                    )
                ]
            )
            let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))

            try await action.perform(adapter, sessionRecord(providerId: .codex, workingDirectory: nil))

            let requestMethods = await transport.requestMethods

            XCTAssertEqual(requestMethods, ["initialize", action.method])
        }
    }

    func testDeleteSurfacesNonRolloutJSONRPCFailure() async throws {
        let transport = FakeCodexAppServerTransport(
            threadIds: [],
            requestErrors: [
                "thread/delete": .jsonRPCError(
                    method: "thread/delete",
                    code: -32603,
                    message: "failed to delete app-server state: no such table: agent_jobs"
                )
            ]
        )
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))

        do {
            try await adapter.deleteSession(sessionRecord(providerId: .codex))
            XCTFail("Expected JSON-RPC failure.")
        } catch let error as CodexAppServerError {
            guard case let .jsonRPCError(method, code, _) = error else {
                XCTFail("Expected JSON-RPC error, got \(error).")
                return
            }
            XCTAssertEqual(method, "thread/delete")
            XCTAssertEqual(code, -32603)
        }
    }

    func testProviderResourcesCanShutdownAfterOneShotArchive() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: [])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))

        try await adapter.archiveSession(sessionRecord(providerId: .codex))
        await adapter.shutdownProviderResources()

        let shutdownCount = await transport.shutdownCount

        XCTAssertEqual(shutdownCount, 1)
    }

    func testAppServerErrorsMapToDiagnosticCodes() {
        XCTAssertEqual(
            CodexAppServerError.requestTimeout(method: "thread/start", seconds: 1).diagnosticCode,
            .codexAppServerRequestTimeout
        )
        XCTAssertEqual(
            CodexAppServerError.jsonRPCError(method: "thread/start", code: -32600, message: "Bad request").diagnosticCode,
            .codexAppServerJSONRPCError
        )
        XCTAssertEqual(
            CodexAppServerError.appServerExited(exitCode: 1, stderrTail: "crashed").diagnosticCode,
            .codexAppServerCrash
        )
        XCTAssertEqual(
            CodexAppServerError.shutdownTimeout(seconds: 1).diagnosticCode,
            .codexAppServerShutdownTimeout
        )
    }

    func supersedingSessionRecord(supersededSessionIds: [String]) -> AgentSessionRecord {
        AgentSessionRecord(
            conversationId: "conversation",
            providerId: .codex,
            providerSessionId: "thread-123",
            generation: 0,
            metadata: [
                AgentSessionRecord.supersededProviderSessionIdsMetadataKey: .array(supersededSessionIds.map(JSONValue.string))
            ]
        )
    }

    func sessionRecord(providerId: AgentProviderID, workingDirectory: URL? = URL(fileURLWithPath: "/tmp/project")) -> AgentSessionRecord {
        AgentSessionRecord(
            conversationId: "conversation",
            providerId: providerId,
            providerSessionId: "thread-123",
            workingDirectory: workingDirectory,
            generation: 0
        )
    }

    func configuration(
        transport: FakeCodexAppServerTransport,
        executablePath: String = "/usr/bin/env",
        executableResolver: any AgentProviderExecutableResolving = RecordingExecutableResolver(path: nil),
        recorder: CodexTransportConfigurationRecorder? = nil,
        featureSupportChecker: any CodexFeatureSupportChecking = FixedCodexFeatureSupportChecker(supportsFastMode: false, supportsGoalMode: false)
    ) -> CodexProviderAdapter.Configuration {
        CodexProviderAdapter.Configuration(
            executablePath: executablePath,
            requestTimeout: 0.1,
            probeTimeout: 0.1,
            featureSupportChecker: featureSupportChecker,
            makeTransport: { configuration in
                recorder?.record(configuration)
                return transport
            },
            executableResolver: executableResolver
        )
    }

}

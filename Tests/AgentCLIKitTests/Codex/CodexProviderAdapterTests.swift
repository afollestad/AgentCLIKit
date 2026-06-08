import Foundation
import XCTest

@testable import AgentCLIKit

final class CodexProviderAdapterTests: XCTestCase {
    func testBootstrapsThreadLazilyAndPersistsThreadIdFromSentinel() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"], threadNames: ["Build Parser"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))

        let startCountBeforeLaunch = await transport.startCount

        let launch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                providerId: .codex,
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                model: "model-a",
                effort: "high",
                permissionMode: "on-request"
            ),
            resumedSession: nil
        )
        let line = try XCTUnwrap(launch.arguments.last)
        let events = try await adapter.decodeStdoutLine(line)
        let sessionId = events.compactMap(adapter.sessionID(from:)).first
        let metadata = try XCTUnwrap(events.compactMap(\.sessionMetadataEvent).first)
        let startCount = await transport.startCount
        let requestMethods = await transport.requestMethods
        let notificationMethods = await transport.notificationMethods
        let requestParams = await transport.requestParams

        XCTAssertEqual(startCountBeforeLaunch, 0)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(requestMethods, ["initialize", "thread/start"])
        XCTAssertEqual(notificationMethods, ["initialized"])
        XCTAssertEqual(launch.executable, "/usr/bin/env")
        XCTAssertEqual(launch.arguments.prefix(3), ["sh", "-c", "printf '%s\\n' \"$1\"; sleep 2147483647"])
        XCTAssertEqual(launch.sessionContinuity, .fresh)
        XCTAssertEqual(launch.providerSessionId, "thread-123")
        XCTAssertTrue(launch.includesSpawnArguments)
        XCTAssertEqual(sessionId, "thread-123")
        XCTAssertEqual(metadata.providerSessionId, "thread-123")
        XCTAssertEqual(metadata.name, "Build Parser")

        let threadStartParams = try XCTUnwrap(requestParams["thread/start"])
        XCTAssertEqual(threadStartParams.objectValue?["cwd"], .string("/tmp/project"))
        XCTAssertEqual(threadStartParams.objectValue?["model"], .string("model-a"))
        XCTAssertEqual(threadStartParams.objectValue?["approvalPolicy"], .string("on-request"))
        XCTAssertEqual(threadStartParams.objectValue?["ephemeral"], .bool(false))
        XCTAssertEqual(threadStartParams.objectValue?["config"], .object(["model_reasoning_effort": .string("high")]))
    }

    func testResumesSavedThreadId() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-existing"], threadNames: ["Existing Thread"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let resumedSession = AgentSessionRecord(
            conversationId: "conversation",
            providerId: .codex,
            providerSessionId: "thread-existing",
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            generation: 1
        )

        let launch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project")),
            resumedSession: resumedSession
        )

        let line = try XCTUnwrap(launch.arguments.last)
        let events = try await adapter.decodeStdoutLine(line)
        let metadata = try XCTUnwrap(events.compactMap(\.sessionMetadataEvent).first)
        let requestMethods = await transport.requestMethods
        let requestParams = await transport.requestParams

        XCTAssertEqual(requestMethods, ["initialize", "thread/resume"])
        XCTAssertEqual(launch.sessionContinuity, AgentSessionContinuity.resumed)
        XCTAssertEqual(launch.providerSessionId, "thread-existing")
        XCTAssertEqual(metadata.providerSessionId, "thread-existing")
        XCTAssertEqual(metadata.name, "Existing Thread")
        let threadResumeParams = try XCTUnwrap(requestParams["thread/resume"])
        XCTAssertEqual(threadResumeParams.objectValue?["threadId"], .string("thread-existing"))
    }

    func testReusesSharedTransportAcrossThreadBootstraps() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-1", "thread-2"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let spawnConfig = AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project"))

        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)
        _ = try await adapter.makeLaunchConfiguration(spawnConfig: spawnConfig, resumedSession: nil)

        let startCount = await transport.startCount
        let requestMethods = await transport.requestMethods
        let notificationMethods = await transport.notificationMethods

        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(requestMethods, ["initialize", "thread/start", "thread/start"])
        XCTAssertEqual(notificationMethods, ["initialized"])
    }

    func testRuntimeTransportUsesResolvedCodexExecutable() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let resolver = RecordingExecutableResolver(path: "/Users/test/.local/bin/codex")
        let recorder = CodexTransportConfigurationRecorder()
        let adapter = CodexProviderAdapter(configuration: configuration(
            transport: transport,
            executableResolver: resolver,
            recorder: recorder
        ))

        _ = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project")),
            resumedSession: nil
        )
        let requestedDefinitions = await resolver.requestedDefinitions

        XCTAssertEqual(requestedDefinitions.map(\.id), [.codex])
        XCTAssertEqual(recorder.executablePaths, ["/Users/test/.local/bin/codex"])
    }

    func testRuntimeTransportKeepsEnvFallbackWhenResolverMisses() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let resolver = RecordingExecutableResolver(path: nil)
        let recorder = CodexTransportConfigurationRecorder()
        let adapter = CodexProviderAdapter(configuration: configuration(
            transport: transport,
            executableResolver: resolver,
            recorder: recorder
        ))

        _ = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project")),
            resumedSession: nil
        )
        let requestedDefinitions = await resolver.requestedDefinitions

        XCTAssertEqual(requestedDefinitions.map(\.id), [.codex])
        XCTAssertEqual(recorder.executablePaths, ["/usr/bin/env"])
    }

    func testExactCodexExecutableBypassesResolver() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let resolver = RecordingExecutableResolver(path: "/Users/test/.local/bin/codex")
        let recorder = CodexTransportConfigurationRecorder()
        let adapter = CodexProviderAdapter(configuration: configuration(
            transport: transport,
            executablePath: "/opt/homebrew/bin/codex",
            executableResolver: resolver,
            recorder: recorder
        ))

        _ = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project")),
            resumedSession: nil
        )
        let requestedDefinitions = await resolver.requestedDefinitions

        XCTAssertEqual(requestedDefinitions.map(\.id), [])
        XCTAssertEqual(recorder.executablePaths, ["/opt/homebrew/bin/codex"])
    }

    func testShutdownStopsSharedTransport() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))

        _ = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: "/tmp/project")),
            resumedSession: nil
        )
        await adapter.shutdownProviderResources()
        let shutdownCount = await transport.shutdownCount

        XCTAssertEqual(shutdownCount, 1)
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

    private func sessionRecord(providerId: AgentProviderID, workingDirectory: URL? = URL(fileURLWithPath: "/tmp/project")) -> AgentSessionRecord {
        AgentSessionRecord(
            conversationId: "conversation",
            providerId: providerId,
            providerSessionId: "thread-123",
            workingDirectory: workingDirectory,
            generation: 0
        )
    }

    private func configuration(
        transport: FakeCodexAppServerTransport,
        executablePath: String = "/usr/bin/env",
        executableResolver: any AgentProviderExecutableResolving = RecordingExecutableResolver(path: nil),
        recorder: CodexTransportConfigurationRecorder? = nil
    ) -> CodexProviderAdapter.Configuration {
        CodexProviderAdapter.Configuration(
            executablePath: executablePath,
            requestTimeout: 0.1,
            probeTimeout: 0.1,
            makeTransport: { configuration in
                recorder?.record(configuration)
                return transport
            },
            executableResolver: executableResolver
        )
    }

}

private extension AgentEvent {
    var sessionMetadataEvent: AgentSessionMetadataEvent? {
        guard case let .sessionMetadata(metadata) = self else {
            return nil
        }
        return metadata
    }
}

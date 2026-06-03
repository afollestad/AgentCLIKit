import Foundation
import XCTest

@testable import AgentCLIKit

final class CodexProviderAdapterTests: XCTestCase {
    func testBootstrapsThreadLazilyAndPersistsThreadIdFromSentinel() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-123"])
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
        XCTAssertTrue(launch.includesSpawnArguments)
        XCTAssertEqual(sessionId, "thread-123")

        let threadStartParams = try XCTUnwrap(requestParams["thread/start"])
        XCTAssertEqual(threadStartParams.objectValue?["cwd"], .string("/tmp/project"))
        XCTAssertEqual(threadStartParams.objectValue?["model"], .string("model-a"))
        XCTAssertEqual(threadStartParams.objectValue?["approvalPolicy"], .string("on-request"))
        XCTAssertEqual(threadStartParams.objectValue?["ephemeral"], .bool(false))
        XCTAssertEqual(threadStartParams.objectValue?["config"], .object(["model_reasoning_effort": .string("high")]))
    }

    func testResumesSavedThreadId() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-existing"])
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

        let requestMethods = await transport.requestMethods
        let requestParams = await transport.requestParams

        XCTAssertEqual(requestMethods, ["initialize", "thread/resume"])
        XCTAssertEqual(launch.sessionContinuity, AgentSessionContinuity.resumed)
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

    func testTurnInputIsExplicitlyUnsupportedUntilTurnMappingLands() async throws {
        let adapter = CodexProviderAdapter(configuration: configuration(transport: FakeCodexAppServerTransport(threadIds: ["thread-123"])))

        do {
            _ = try await adapter.encodeInput(.userMessage(AgentMessageInput(text: "Hello")))
            XCTFail("Expected Codex turn input to be unsupported in Phase 5.")
        } catch let error as AgentCLIError {
            guard case let .invalidInput(message) = error else {
                XCTFail("Expected invalidInput, got \(error).")
                return
            }
            XCTAssertTrue(message.contains("turn input is not implemented"))
        }
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

    private func configuration(transport: FakeCodexAppServerTransport) -> CodexProviderAdapter.Configuration {
        CodexProviderAdapter.Configuration(
            requestTimeout: 0.1,
            probeTimeout: 0.1,
            makeTransport: { _ in transport }
        )
    }
}

private actor FakeCodexAppServerTransport: CodexAppServerTransport {
    private var threadIds: [String]
    private(set) var startCount = 0
    private(set) var shutdownCount = 0
    private(set) var requestMethods: [String] = []
    private(set) var notificationMethods: [String] = []
    private(set) var requestParams: [String: JSONValue] = [:]

    init(threadIds: [String]) {
        self.threadIds = threadIds
    }

    func start() async throws {
        startCount += 1
    }

    func sendRequest(method: String, params: JSONValue?) async throws -> JSONValue {
        requestMethods.append(method)
        requestParams[method] = params
        switch method {
        case "initialize":
            return .object(["server": .string("fake")])
        case "thread/start", "thread/resume":
            return .object([
                "thread": .object([
                    "id": .string(threadIds.removeFirst())
                ])
            ])
        default:
            return .null
        }
    }

    func sendNotification(method: String, params: JSONValue?) async throws {
        notificationMethods.append(method)
    }

    func shutdown() async {
        shutdownCount += 1
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else {
            return nil
        }
        return value
    }
}

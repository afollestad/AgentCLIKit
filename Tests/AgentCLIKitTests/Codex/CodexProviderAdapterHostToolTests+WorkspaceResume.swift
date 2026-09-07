import Foundation
import XCTest

@testable import AgentCLIKit

extension CodexProviderAdapterHostToolTests {
    static func configuration(
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

    func testResumeWithoutHostToolsForksWithExplicitRoots() async throws {
        try await assertWorkspaceResume(grants: ["/tmp/grant"], expectedMethod: "thread/fork")
    }

    func testResumeWithoutHostToolsForksToRevokeFinalGrant() async throws {
        try await assertWorkspaceResume(grants: ["/tmp/project"], expectedMethod: "thread/fork")
    }

    func testResumeWithoutRootOverrideKeepsNativeResume() async throws {
        try await assertWorkspaceResume(grants: [], expectedMethod: "thread/resume")
    }

    func testUnsupportedResumeRootsFailWithoutRetryingOrDroppingGrants() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: [], requestErrors: [
            "thread/fork": .jsonRPCError(method: "thread/fork", code: -32602, message: "unknown field runtimeWorkspaceRoots")
        ])
        let adapter = CodexProviderAdapter(configuration: Self.configuration(transport: transport))
        let directory = URL(fileURLWithPath: "/tmp/project")
        do {
            _ = try await adapter.makeLaunchConfiguration(
                spawnConfig: AgentSpawnConfig(providerId: .codex, workingDirectory: directory, additionalWorkspaceRoots: [directory]),
                resumedSession: workspaceSession(id: "existing-thread", directory: directory)
            )
            XCTFail("Expected an explicit root override to fail when unsupported.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error.code, .unsupportedCapability)
        }
        let methods = await transport.requestMethods
        XCTAssertEqual(methods, ["initialize", "thread/fork"])
    }

    func testExplicitWorkspaceForkSourceWinsOverResumedSession() async throws {
        try await assertWorkspaceResume(
            grants: ["/tmp/grant"],
            expectedMethod: "thread/fork",
            explicitSource: "explicit-source"
        )
    }

    func testRelaunchAfterSuspensionReplacesPreviouslyLoadedRootsWithoutHostTools() async throws {
        let workingDirectory = URL(fileURLWithPath: "/tmp/project")
        let transport = FakeCodexAppServerTransport(threadIds: ["loaded-thread", "replacement-thread"])
        let adapter = CodexProviderAdapter(configuration: Self.configuration(transport: transport))
        _ = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                providerId: .codex,
                workingDirectory: workingDirectory,
                additionalWorkspaceRoots: [URL(fileURLWithPath: "/tmp/old-grant")]
            ),
            resumedSession: nil
        )

        let launch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                providerId: .codex,
                workingDirectory: workingDirectory,
                additionalWorkspaceRoots: [URL(fileURLWithPath: "/tmp/new-grant")]
            ),
            resumedSession: workspaceSession(id: "loaded-thread", directory: workingDirectory)
        )

        let methods = await transport.requestMethods
        let params = await transport.requestParams
        XCTAssertEqual(methods, ["initialize", "thread/start", "thread/fork"])
        XCTAssertEqual(launch.providerSessionId, "replacement-thread")
        XCTAssertEqual(params["thread/fork"]?.objectValue?["runtimeWorkspaceRoots"], .array([
            .string("/tmp/project"), .string("/tmp/new-grant")
        ]))
    }
}

private extension CodexProviderAdapterHostToolTests {
    func assertWorkspaceResume(
        grants: [String],
        expectedMethod: String,
        explicitSource: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let directory = URL(fileURLWithPath: "/tmp/project")
        let transport = FakeCodexAppServerTransport(threadIds: ["result-thread"])
        let adapter = CodexProviderAdapter(configuration: Self.configuration(transport: transport))
        let config = AgentSpawnConfig(
            providerId: .codex,
            workingDirectory: directory,
            sessionFork: explicitSource.map {
                AgentSessionForkRequest(sourceSessionId: AgentSessionID(rawValue: $0), sourceWorkingDirectory: directory, mode: .local)
            },
            additionalWorkspaceRoots: grants.map { URL(fileURLWithPath: $0) }
        )

        let launch = try await adapter.makeLaunchConfiguration(
            spawnConfig: config,
            resumedSession: workspaceSession(id: "existing-thread", directory: directory)
        )
        let methods = await transport.requestMethods
        let requests = await transport.requestParams
        let params = try XCTUnwrap(requests[expectedMethod]?.objectValue, file: file, line: line)
        XCTAssertEqual(methods, ["initialize", expectedMethod], file: file, line: line)
        XCTAssertEqual(params["threadId"], .string(explicitSource ?? "existing-thread"), file: file, line: line)
        XCTAssertNil(params["developerInstructions"], file: file, line: line)
        if grants.isEmpty {
            XCTAssertNil(params["runtimeWorkspaceRoots"], file: file, line: line)
            XCTAssertEqual(launch.sessionContinuity, .resumed, file: file, line: line)
        } else {
            let expectedRoots = ["/tmp/project"] + grants.filter { $0 != "/tmp/project" }
            XCTAssertEqual(params["runtimeWorkspaceRoots"], .array(expectedRoots.map(JSONValue.string)), file: file, line: line)
            XCTAssertEqual(launch.sessionContinuity, .forked, file: file, line: line)
        }
    }

    func workspaceSession(id: String, directory: URL) -> AgentSessionRecord {
        AgentSessionRecord(
            conversationId: "conversation",
            providerId: .codex,
            providerSessionId: AgentSessionID(rawValue: id),
            workingDirectory: directory,
            generation: 1
        )
    }
}

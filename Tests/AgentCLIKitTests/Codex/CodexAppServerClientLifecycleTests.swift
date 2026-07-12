import XCTest

@testable import AgentCLIKit

final class CodexAppServerClientLifecycleTests: XCTestCase {
    func testConcurrentBootstrapsShareTransportStartAndInitialization() async throws {
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-1", "thread-2"])
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let firstConfig = spawnConfig(path: "/tmp/first")
        let secondConfig = spawnConfig(path: "/tmp/second")

        async let first = adapter.makeLaunchConfiguration(spawnConfig: firstConfig, resumedSession: nil)
        async let second = adapter.makeLaunchConfiguration(spawnConfig: secondConfig, resumedSession: nil)
        _ = try await (first, second)

        let startCount = await transport.startCount
        let requestMethods = await transport.requestMethods
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(requestMethods.filter { $0 == "initialize" }.count, 1)
        XCTAssertEqual(requestMethods.filter { $0 == "thread/start" }.count, 2)

        await adapter.shutdownProviderResources()
    }

    func testShutdownDuringTransportStartStopsResourceAndRejectsLateLaunch() async {
        let gate = FakeCodexTransportStartGate()
        let transport = FakeCodexAppServerTransport(threadIds: ["thread-1"], startGate: gate)
        let adapter = CodexProviderAdapter(configuration: configuration(transport: transport))
        let config = spawnConfig(path: "/tmp/project")
        let launchTask = Task {
            try await adapter.makeLaunchConfiguration(spawnConfig: config, resumedSession: nil)
        }
        await gate.waitUntilStarted()

        let shutdownTask = Task {
            await adapter.shutdownProviderResources()
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await gate.resume()
        await shutdownTask.value

        await assertLaunchFailsAfterShutdown(launchTask)
        let shutdownCount = await transport.shutdownCount
        let startCount = await transport.startCount
        XCTAssertEqual(shutdownCount, 1)
        XCTAssertEqual(startCount, 1)

        do {
            _ = try await adapter.makeLaunchConfiguration(spawnConfig: config, resumedSession: nil)
            XCTFail("Expected future launches to fail after provider shutdown.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("client has shut down"))
        }
        let finalStartCount = await transport.startCount
        XCTAssertEqual(finalStartCount, 1)
    }

    private func assertLaunchFailsAfterShutdown(
        _ launchTask: Task<AgentLaunchConfiguration, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await launchTask.value
            XCTFail("Expected pending launch to fail after provider shutdown.", file: file, line: line)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("client has shut down"), file: file, line: line)
        }
    }

    private func configuration(transport: FakeCodexAppServerTransport) -> CodexProviderAdapter.Configuration {
        CodexProviderAdapter.Configuration(
            requestTimeout: 0.1,
            probeTimeout: 0.1,
            featureSupportChecker: FixedCodexFeatureSupportChecker(supportsFastMode: false, supportsGoalMode: false),
            makeTransport: { _ in transport },
            executableResolver: RecordingExecutableResolver(path: nil)
        )
    }

    private func spawnConfig(path: String) -> AgentSpawnConfig {
        AgentSpawnConfig(providerId: .codex, workingDirectory: URL(fileURLWithPath: path))
    }
}

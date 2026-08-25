import XCTest

@testable import AgentCLIKit

/// Covers how `ClaudeProviderSetup` maps a probe verdict onto `AgentProviderReadinessState`, which is
/// what every downstream readiness gate reads.
final class ClaudeProviderSetupAuthTests: XCTestCase {
    func testSignedOutProbeReportsNeedsSetupWithDiagnostic() async {
        let setup = Self.setup(stdout: #"{"loggedIn":false}"#)

        let readiness = await setup.setupReadiness()
        let diagnostics = await setup.setupDiagnostics()

        XCTAssertEqual(readiness, .needsSetup)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertTrue(diagnostics[0].contains("claude auth login"))
    }

    /// Discovery builds one status by calling readiness then diagnostics, so a re-probing
    /// `setupDiagnostics()` would double the CLI spawns per refresh.
    func testDiagnosticsAfterReadinessDoesNotSpawnAgain() async {
        let runner = CountingShellRunner(result: ShellCommandResult(exitCode: 0, stdout: #"{"loggedIn":false}"#, stderr: ""))
        let setup = Self.setup(runner: runner)

        _ = await setup.setupReadiness()
        _ = await setup.setupDiagnostics()

        let runCount = await runner.runCount()
        XCTAssertEqual(runCount, 1)
    }

    func testDiagnosticsProbesWhenNothingHasBeenProbedYet() async {
        let runner = CountingShellRunner(result: ShellCommandResult(exitCode: 0, stdout: #"{"loggedIn":false}"#, stderr: ""))
        let setup = Self.setup(runner: runner)

        let diagnostics = await setup.setupDiagnostics()

        XCTAssertEqual(diagnostics.count, 1)
        let runCount = await runner.runCount()
        XCTAssertEqual(runCount, 1)
    }

    func testSignedInProbeReportsReady() async {
        let setup = Self.setup(stdout: #"{"loggedIn":true,"authMethod":"claude.ai"}"#)

        let readiness = await setup.setupReadiness()
        let diagnostics = await setup.setupDiagnostics()

        XCTAssertEqual(readiness, .ready)
        XCTAssertTrue(diagnostics.isEmpty)
    }

    func testInconclusiveProbeReportsReadyRatherThanLockingTheUserOut() async {
        let setup = Self.setup(stdout: "", exitCode: 1)

        let readiness = await setup.setupReadiness()

        XCTAssertEqual(readiness, .ready)
    }

    func testSetupWithoutProbeReportsReady() async {
        let setup = ClaudeProviderSetup(configStore: ClaudeConfigStore(fileURL: Self.scratchConfigURL()))

        let readiness = await setup.setupReadiness()

        XCTAssertEqual(setup.cachedSetupReadiness(), .ready)
        XCTAssertEqual(readiness, .ready)
        let diagnostics = await setup.setupDiagnostics()
        XCTAssertTrue(diagnostics.isEmpty)
        let authReadiness = await setup.authReadiness()
        XCTAssertNil(authReadiness)
    }

    func testCachedReadinessReportsReadyBeforeTheFirstProbeAndTheVerdictAfter() async {
        let setup = Self.setup(stdout: #"{"loggedIn":false}"#)

        XCTAssertEqual(setup.cachedSetupReadiness(), .ready)
        _ = await setup.setupReadiness()

        XCTAssertEqual(setup.cachedSetupReadiness(), .needsSetup)
    }
}

private extension ClaudeProviderSetupAuthTests {
    static func setup(stdout: String, exitCode: Int32 = 0) -> ClaudeProviderSetup {
        setup(runner: CountingShellRunner(result: ShellCommandResult(exitCode: exitCode, stdout: stdout, stderr: "")))
    }

    static func setup(runner: any ShellRunning) -> ClaudeProviderSetup {
        ClaudeProviderSetup(
            configStore: ClaudeConfigStore(fileURL: scratchConfigURL()),
            authProbe: ClaudeAuthProbe(
                shellRunner: runner,
                environment: [:],
                executablePath: { "/usr/local/bin/claude" }
            )
        )
    }

    /// A path under a fresh temporary directory, so trust reads never touch the developer's real
    /// `~/.claude.json`.
    static func scratchConfigURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("claude.json")
    }
}

/// Counts spawns so a test can assert how many times the probe reached for the CLI.
private actor CountingShellRunner: ShellRunning {
    private let result: ShellCommandResult
    private var runs = 0

    init(result: ShellCommandResult) {
        self.result = result
    }

    func run(_ command: ShellCommand) async throws -> ShellCommandResult {
        runs += 1
        return result
    }

    func runCount() -> Int {
        runs
    }
}

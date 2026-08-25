import XCTest

@testable import AgentCLIKit

final class ClaudeAuthProbeTests: XCTestCase {
    func testEnvironmentAPIKeyReportsReadyWithoutSpawning() async {
        let runner = RecordingShellRunner(result: ShellCommandResult(exitCode: 1, stdout: "", stderr: ""))
        let probe = Self.probe(runner: runner, environment: ["ANTHROPIC_API_KEY": "sk-test"])

        let readiness = await probe.readiness()

        XCTAssertEqual(readiness.state, .ready)
        XCTAssertEqual(readiness.credentialSource, .environmentAPIKey)
        let commands = await runner.commands()
        XCTAssertTrue(commands.isEmpty)
    }

    func testEnvironmentAuthTokenReportsReadyWithoutSpawning() async {
        let runner = RecordingShellRunner(result: ShellCommandResult(exitCode: 1, stdout: "", stderr: ""))
        let probe = Self.probe(runner: runner, environment: ["ANTHROPIC_AUTH_TOKEN": "token"])

        let readiness = await probe.readiness()

        XCTAssertEqual(readiness.state, .ready)
        XCTAssertEqual(readiness.credentialSource, .environmentAuthToken)
        let commands = await runner.commands()
        XCTAssertTrue(commands.isEmpty)
    }

    func testEmptyEnvironmentValueDoesNotCountAsCredential() async {
        let runner = RecordingShellRunner(result: Self.signedInResult)
        let probe = Self.probe(runner: runner, environment: ["ANTHROPIC_API_KEY": ""])

        let readiness = await probe.readiness()

        XCTAssertEqual(readiness.credentialSource, .cliAuthStatus)
    }

    func testSignedInStatusReportsReady() async {
        let runner = RecordingShellRunner(result: Self.signedInResult)
        let probe = Self.probe(runner: runner)

        let readiness = await probe.readiness()

        XCTAssertEqual(readiness.state, .ready)
        XCTAssertEqual(readiness.credentialSource, .cliAuthStatus)
        XCTAssertEqual(readiness.authMethod, "claude.ai")
        XCTAssertEqual(readiness.accountEmail, "person@example.com")
        XCTAssertTrue(readiness.diagnostics.isEmpty)
        let commands = await runner.commands()
        XCTAssertEqual(commands.map(\.arguments), [["auth", "status", "--json"]])
        XCTAssertEqual(commands.map(\.executable), ["/usr/local/bin/claude"])
    }

    func testSignedOutStatusReportsSignedOutAndBlocksWork() async {
        let result = ShellCommandResult(exitCode: 0, stdout: #"{"loggedIn":false}"#, stderr: "")
        let probe = Self.probe(runner: RecordingShellRunner(result: result))

        let readiness = await probe.readiness()

        XCTAssertEqual(readiness.state, .signedOut)
        XCTAssertFalse(readiness.allowsProviderWork)
        XCTAssertEqual(readiness.diagnostics.count, 1)
        XCTAssertTrue(readiness.diagnostics[0].contains("claude auth login"))
    }

    func testNonZeroExitReportsUnknownAndAllowsWork() async {
        let result = ShellCommandResult(exitCode: 2, stdout: "", stderr: "boom")
        let probe = Self.probe(runner: RecordingShellRunner(result: result))

        let readiness = await probe.readiness()

        XCTAssertEqual(readiness.state, .unknown)
        XCTAssertTrue(readiness.allowsProviderWork)
        XCTAssertEqual(readiness.diagnostics, ["Checking the Claude sign-in state failed: boom"])
    }

    func testThrownRunReportsUnknown() async {
        let probe = Self.probe(runner: RecordingShellRunner(error: .commandLaunchFailed(executable: "claude", reason: "nope")))

        let readiness = await probe.readiness()

        XCTAssertEqual(readiness.state, .unknown)
        XCTAssertTrue(readiness.allowsProviderWork)
    }

    func testAbsentLoggedInKeyReportsUnknownRatherThanSignedOut() async {
        let result = ShellCommandResult(exitCode: 0, stdout: #"{"logged_in":true,"authMethod":"claude.ai"}"#, stderr: "")
        let probe = Self.probe(runner: RecordingShellRunner(result: result))

        let readiness = await probe.readiness()

        XCTAssertEqual(readiness.state, .unknown)
        XCTAssertTrue(readiness.allowsProviderWork)
    }

    func testUndecodableOutputReportsUnknown() async {
        let result = ShellCommandResult(exitCode: 0, stdout: "not json at all", stderr: "")
        let probe = Self.probe(runner: RecordingShellRunner(result: result))

        let readiness = await probe.readiness()

        XCTAssertEqual(readiness.state, .unknown)
    }

    func testDecodesStatusSurroundedByNoise() async {
        let stdout = "Update available\n{\"loggedIn\":true,\"authMethod\":\"claude.ai\"}\ntrailing\n"
        let probe = Self.probe(runner: RecordingShellRunner(result: ShellCommandResult(exitCode: 0, stdout: stdout, stderr: "")))

        let readiness = await probe.readiness()

        XCTAssertEqual(readiness.state, .ready)
        XCTAssertEqual(readiness.authMethod, "claude.ai")
    }

    func testMissingExecutableReportsUnknown() async {
        let probe = ClaudeAuthProbe(
            shellRunner: RecordingShellRunner(result: Self.signedInResult),
            environment: [:],
            executablePath: { nil }
        )

        let readiness = await probe.readiness()

        XCTAssertEqual(readiness.state, .unknown)
        XCTAssertTrue(readiness.allowsProviderWork)
    }

    func testProbeTimesOutIntoUnknown() async {
        let probe = ClaudeAuthProbe(
            shellRunner: HangingShellRunner(),
            environment: [:],
            timeout: .milliseconds(20),
            executablePath: { "/usr/local/bin/claude" }
        )

        let readiness = await probe.readiness()

        XCTAssertEqual(readiness.state, .unknown)
        XCTAssertTrue(readiness.allowsProviderWork)
    }
}

private extension ClaudeAuthProbeTests {
    static let signedInResult = ShellCommandResult(
        exitCode: 0,
        stdout: #"{"loggedIn":true,"authMethod":"claude.ai","email":"person@example.com","subscriptionType":"enterprise"}"#,
        stderr: ""
    )

    static func probe(
        runner: any ShellRunning,
        environment: [String: String] = [:]
    ) -> ClaudeAuthProbe {
        ClaudeAuthProbe(
            shellRunner: runner,
            environment: environment,
            executablePath: { "/usr/local/bin/claude" }
        )
    }
}

/// Answers every command with one canned response, so a test does not have to reconstruct the exact
/// `ShellCommand` key `FakeShellRunner` matches on.
private actor RecordingShellRunner: ShellRunning {
    private let result: ShellCommandResult?
    private let error: AgentCLIError?
    private var recordedCommands: [ShellCommand] = []

    init(result: ShellCommandResult) {
        self.result = result
        self.error = nil
    }

    init(error: AgentCLIError) {
        self.result = nil
        self.error = error
    }

    func run(_ command: ShellCommand) async throws -> ShellCommandResult {
        recordedCommands.append(command)
        if let error {
            throw error
        }
        guard let result else {
            throw AgentCLIError.commandLaunchFailed(executable: command.executable, reason: "no stubbed result")
        }
        return result
    }

    func commands() -> [ShellCommand] {
        recordedCommands
    }
}

/// Never returns until cancelled, so the probe's timeout is what ends the call.
private struct HangingShellRunner: ShellRunning {
    func run(_ command: ShellCommand) async throws -> ShellCommandResult {
        try await Task.sleep(for: .seconds(60))
        return ShellCommandResult(exitCode: 0, stdout: "", stderr: "")
    }
}

import XCTest

@testable import AgentCLIKit

final class AgentOneShotPromptRunnerTests: XCTestCase {
    func testCodexOneShotUsesEphemeralReadOnlyExec() async throws {
        let request = AgentOneShotPromptRequest(
            providerId: .codex,
            workingDirectory: Self.workingDirectory,
            prompt: "Say CODEX-OK",
            environment: ["AGENT_TEST": "1"],
            model: "gpt-5",
            effort: "medium",
            timeout: 1
        )
        let expectedCommand = Self.codexCommand(
            prompt: "Say CODEX-OK",
            environment: ["AGENT_TEST": "1"],
            model: "gpt-5",
            effort: "medium"
        )
        let shellRunner = FakeShellRunner(results: [
            expectedCommand: .success(ShellCommandResult(
                exitCode: 0,
                stdout: """
                {"type":"thread.started","thread_id":"thread-123"}
                {"type":"item.completed","item":{"type":"agent_message","text":"CODEX-OK"}}
                """,
                stderr: "watcher warning\n"
            ))
        ])
        let runner = Self.runner(shellRunner: shellRunner, executablePath: "/opt/codex")

        let result = try await runner.generate(request)
        let commands = await shellRunner.commands()

        XCTAssertEqual(result.text, "CODEX-OK")
        XCTAssertEqual(result.stderr, "watcher warning\n")
        XCTAssertEqual(commands, [expectedCommand])
    }

    func testClaudeOneShotUsesSafeModeNoPersistenceAndReadOnlyTools() async throws {
        let request = AgentOneShotPromptRequest(
            providerId: .claude,
            workingDirectory: Self.workingDirectory,
            prompt: "Say CLAUDE-OK",
            arguments: ["--append-system-prompt", "Use terse output"],
            environment: ["AGENT_TEST": "1"]
        )
        let expectedCommand = Self.claudeCommand(
            prompt: "Say CLAUDE-OK",
            arguments: ["--append-system-prompt", "Use terse output"],
            environment: ["AGENT_TEST": "1"],
            model: "sonnet"
        )
        let shellRunner = FakeShellRunner(results: [
            expectedCommand: .success(ShellCommandResult(
                exitCode: 0,
                stdout: """
                {"type":"system","subtype":"init"}
                {"type":"result","subtype":"success","is_error":false,"result":"CLAUDE-OK"}
                """,
                stderr: ""
            ))
        ])
        let runner = Self.runner(shellRunner: shellRunner, executablePath: "/opt/claude")

        let result = try await runner.generate(request)
        let commands = await shellRunner.commands()

        XCTAssertEqual(result.text, "CLAUDE-OK")
        XCTAssertEqual(commands, [expectedCommand])
    }

    func testClaudeOneShotNormalizesUnavailableModelFailure() async throws {
        let request = AgentOneShotPromptRequest(
            providerId: .claude,
            workingDirectory: Self.workingDirectory,
            prompt: "Say hello",
            model: "fable"
        )
        let expectedCommand = Self.claudeCommand(prompt: "Say hello", model: "fable")
        let shellRunner = FakeShellRunner(results: [
            expectedCommand: .success(ShellCommandResult(
                exitCode: 1,
                stdout: "",
                stderr: "Claude Fable 5 is currently unavailable. Please select another model.\n"
            ))
        ])
        let runner = Self.runner(shellRunner: shellRunner, executablePath: "/opt/claude")

        do {
            _ = try await runner.generate(request)
            XCTFail("Expected unavailable model error")
        } catch AgentOneShotPromptError.unavailableModel(let providerId, let message) {
            XCTAssertEqual(providerId, .claude)
            XCTAssertTrue(message.contains("currently unavailable"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOneShotRejectsApprovalRequests() async throws {
        let request = AgentOneShotPromptRequest(
            providerId: .codex,
            workingDirectory: Self.workingDirectory,
            prompt: "Edit a file"
        )
        let expectedCommand = Self.codexCommand(prompt: "Edit a file")
        let shellRunner = FakeShellRunner(results: [
            expectedCommand: .success(ShellCommandResult(exitCode: 1, stdout: "", stderr: "approval required for write\n"))
        ])
        let runner = Self.runner(shellRunner: shellRunner, executablePath: "/opt/codex")

        do {
            _ = try await runner.generate(request)
            XCTFail("Expected approval error")
        } catch AgentOneShotPromptError.approvalRequired(let providerId, let message) {
            XCTAssertEqual(providerId, .codex)
            XCTAssertTrue(message.contains("approval required"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOneShotRejectsMalformedSuccessfulStdout() async throws {
        let request = AgentOneShotPromptRequest(
            providerId: .codex,
            workingDirectory: Self.workingDirectory,
            prompt: "Say hello"
        )
        let expectedCommand = Self.codexCommand(prompt: "Say hello")
        let shellRunner = FakeShellRunner(results: [
            expectedCommand: .success(ShellCommandResult(exitCode: 0, stdout: "not-json\n", stderr: ""))
        ])
        let runner = Self.runner(shellRunner: shellRunner, executablePath: "/opt/codex")

        do {
            _ = try await runner.generate(request)
            XCTFail("Expected malformed output error")
        } catch AgentOneShotPromptError.malformedOutput(let providerId, _, let stdout, _) {
            XCTAssertEqual(providerId, .codex)
            XCTAssertEqual(stdout, "not-json\n")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOneShotTimeoutCancelsShellCommand() async throws {
        let runner = Self.runner(shellRunner: SuspendedShellRunner(), executablePath: "/opt/codex")
        let request = AgentOneShotPromptRequest(
            providerId: .codex,
            workingDirectory: Self.workingDirectory,
            prompt: "Say hello",
            timeout: 0.001
        )

        do {
            _ = try await runner.generate(request)
            XCTFail("Expected timeout")
        } catch AgentOneShotPromptError.timedOut(let providerId, _) {
            XCTAssertEqual(providerId, .codex)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOneShotNormalizesCancellation() async throws {
        let runner = Self.runner(shellRunner: CancellingShellRunner(), executablePath: "/opt/codex")
        let request = AgentOneShotPromptRequest(
            providerId: .codex,
            workingDirectory: Self.workingDirectory,
            prompt: "Say hello"
        )

        do {
            _ = try await runner.generate(request)
            XCTFail("Expected cancellation")
        } catch AgentOneShotPromptError.cancelled(let providerId) {
            XCTAssertEqual(providerId, .codex)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private static let workingDirectory = URL(fileURLWithPath: "/tmp/project")

    private static func codexCommand(
        prompt: String,
        environment: [String: String] = [:],
        model: String? = nil,
        effort: String? = nil
    ) -> ShellCommand {
        var arguments = ["exec", "--ephemeral", "--json", "--sandbox", "read-only", "-c", "approval_policy=\"never\"", "-C", "/tmp/project"]
        if let model {
            arguments.append(contentsOf: ["-m", model])
        }
        if let effort {
            arguments.append(contentsOf: ["-c", "model_reasoning_effort=\"\(effort)\""])
        }
        arguments.append("-")
        return ShellCommand(
            executable: "/opt/codex",
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            standardInput: prompt
        )
    }

    private static func claudeCommand(
        prompt: String,
        arguments customArguments: [String] = [],
        environment: [String: String] = [:],
        model: String
    ) -> ShellCommand {
        let arguments = customArguments + [
            "-p", "--safe-mode", "--no-session-persistence", "--output-format", "stream-json", "--input-format",
            "text", "--verbose", "--permission-mode", "default", "--tools", "Read,Grep,Glob,LS", "--model", model, "--effort", "high"
        ]
        return ShellCommand(
            executable: "/opt/claude",
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            standardInput: prompt
        )
    }

    private static func runner(shellRunner: any ShellRunning, executablePath: String) -> DefaultAgentOneShotPromptRunner {
        let resolver = RecordingExecutableResolver(path: executablePath)
        return DefaultAgentOneShotPromptRunner(
            adapters: [
                ClaudeProviderAdapter(configuration: ClaudeProviderAdapter.Configuration(
                    enableHooks: false,
                    executableResolver: resolver
                )),
                CodexProviderAdapter(configuration: CodexProviderAdapter.Configuration(
                    executableResolver: resolver
                ))
            ],
            shellRunner: shellRunner
        )
    }
}

private struct SuspendedShellRunner: ShellRunning {
    func run(_ command: ShellCommand) async throws -> ShellCommandResult {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return ShellCommandResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private struct CancellingShellRunner: ShellRunning {
    func run(_ command: ShellCommand) async throws -> ShellCommandResult {
        throw CancellationError()
    }
}

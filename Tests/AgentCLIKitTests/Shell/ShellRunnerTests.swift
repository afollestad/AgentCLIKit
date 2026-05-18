import XCTest

@testable import AgentCLIKit

final class ShellRunnerTests: XCTestCase {
    func testProcessShellRunnerCollectsOutput() async throws {
        let runner = ProcessShellRunner()

        let result = try await runner.run(ShellCommand(executable: "/bin/echo", arguments: ["hello"]))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "hello\n")
        XCTAssertEqual(result.stderr, "")
    }

    func testProcessShellRunnerResolvesExecutableNameFromPath() async throws {
        let runner = ProcessShellRunner()

        let result = try await runner.run(ShellCommand(executable: "printf", arguments: ["hello"]))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "hello")
    }

    func testProcessShellRunnerDrainsLargeOutputBeforeWaitingForExit() async throws {
        let runner = ProcessShellRunner()

        let result = try await runner.run(ShellCommand(
            executable: "/bin/sh",
            arguments: ["-c", "yes agentclikit | head -n 20000"]
        ))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.split(separator: "\n").count, 20_000)
    }
}

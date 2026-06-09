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

    func testProcessShellRunnerTerminatesProcessOnCancellation() async throws {
        let runner = ProcessShellRunner()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentclikit-shell-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let readyFile = directory.appendingPathComponent("ready")
        let terminatedFile = directory.appendingPathComponent("terminated")
        let completedFile = directory.appendingPathComponent("completed")
        let script = """
        trap 'echo terminated > "$1"; exit 0' TERM
        echo ready > "$2"
        sleep 1
        echo completed > "$3"
        """
        let task = Task {
            try await runner.run(ShellCommand(
                executable: "/bin/sh",
                arguments: ["-c", script, "agentclikit-shell-runner", terminatedFile.path, readyFile.path, completedFile.path]
            ))
        }

        try await waitForFile(at: readyFile)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to throw")
        } catch is CancellationError {
            // Expected.
        }
        try await waitForFile(at: terminatedFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: completedFile.path))
    }

    private func waitForFile(at url: URL, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path) {
            if Date() >= deadline {
                XCTFail("Timed out waiting for \(url.path)")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

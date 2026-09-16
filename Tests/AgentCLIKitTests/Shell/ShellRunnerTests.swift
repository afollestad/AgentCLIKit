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

    func testProcessShellRunnerWritesStandardInput() async throws {
        let runner = ProcessShellRunner()

        let result = try await runner.run(ShellCommand(executable: "/bin/cat", standardInput: "hello stdin"))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "hello stdin")
        XCTAssertEqual(result.stderr, "")
    }

    func testShellCommandDecodesLegacyPayloadWithoutStandardInput() throws {
        let data = Data(#"{"executable":"/bin/echo"}"#.utf8)

        let command = try JSONDecoder().decode(ShellCommand.self, from: data)

        XCTAssertEqual(command.executable, "/bin/echo")
        XCTAssertEqual(command.arguments, [])
        XCTAssertEqual(command.environment, [:])
        XCTAssertTrue(command.inheritsEnvironment)
        XCTAssertNil(command.workingDirectory)
        XCTAssertNil(command.standardInput)
    }

    func testProcessShellRunnerCanReplaceTheInheritedEnvironment() async throws {
        let command = ShellCommand(
            executable: "/usr/bin/env", environment: ["ONLY_THIS_VALUE": "isolated"], inheritsEnvironment: false
        )
        let decoded = try JSONDecoder().decode(ShellCommand.self, from: JSONEncoder().encode(command))
        XCTAssertFalse(decoded.inheritsEnvironment)
        let result = try await ProcessShellRunner().run(decoded)
        XCTAssertEqual(result.stdout, "ONLY_THIS_VALUE=isolated\n")
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

    func testCancellationEscalatesWhenTheProcessIgnoresTermination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shell-ignore-term-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready")
        let script = "import signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); open(sys.argv[1],'w').close(); time.sleep(30)"
        let task = Task {
            try await ProcessShellRunner().run(ShellCommand(executable: "/usr/bin/python3", arguments: ["-c", script, ready.path]))
        }
        try await waitForFile(at: ready)
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testSuccessfulParentExitClosesInheritedDescendantPipes() async throws {
        let script = "import subprocess,sys;subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)']);print('complete',flush=True)"
        let start = Date()
        let result = try await ProcessShellRunner().run(ShellCommand(executable: "/usr/bin/python3", arguments: ["-c", script]))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "complete\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testCancellationBeforeLaunchPublicationDefersUntilGroupOwnershipIsKnown() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let (exits, continuation) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in continuation.finish() }
        let exited = Task { for await _ in exits {} }
        let handler = ProcessCancellationHandler()
        handler.setProcess(process)
        try process.run()
        handler.terminate()
        XCTAssertTrue(process.isRunning)
        handler.didLaunch()
        handler.terminate()
        await handler.waitForTeardown()
        await exited.value
        XCTAssertFalse(process.isRunning)
        handler.clearProcess()
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

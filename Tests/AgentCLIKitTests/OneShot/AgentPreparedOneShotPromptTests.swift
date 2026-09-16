import XCTest

@testable import AgentCLIKit

final class AgentPreparedOneShotPromptTests: XCTestCase {
    func testCancellationClosesInheritedChildPipesBeforeCleanup() async throws {
        let marker = try temporaryMarker()
        let ready = marker.appendingPathExtension("ready")
        defer {
            try? FileManager.default.removeItem(at: marker)
            try? FileManager.default.removeItem(at: ready)
        }
        let child = "import signal,sys,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);open(sys.argv[1],'w').close();time.sleep(30)"
        let parent = """
        import signal,subprocess,sys,time
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        subprocess.Popen([sys.executable,'-c',sys.argv[1],sys.argv[2]])
        time.sleep(30)
        """
        let command = ShellCommand(executable: "/usr/bin/python3", arguments: ["-c", parent, child, ready.path])
        let prepared = AgentPreparedOneShotPrompt(command: command) { try FileManager.default.removeItem(at: marker) }
        let runner = DefaultAgentOneShotPromptRunner(adapters: [PreparedPromptAdapter(prepared: prepared)])
        let request = request
        let task = Task { try await runner.generate(request) }
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: ready.path) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch AgentOneShotPromptError.cancelled { }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testExpiredPreparationDoesNotLaunchAndStillCleansUp() async throws {
        let marker = try temporaryMarker()
        defer { try? FileManager.default.removeItem(at: marker) }
        let prepared = AgentPreparedOneShotPrompt(command: ShellCommand(executable: "unused"), executionDeadline: .distantPast) {
            try FileManager.default.removeItem(at: marker)
        }
        let shell = FakeShellRunner()
        let runner = DefaultAgentOneShotPromptRunner(adapters: [PreparedPromptAdapter(prepared: prepared)], shellRunner: shell)
        do {
            _ = try await runner.generate(request)
            XCTFail("Expected expired preparation")
        } catch AgentOneShotPromptError.timedOut { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let commands = await shell.commands()
        XCTAssertTrue(commands.isEmpty)
    }

    func testCleanupFailurePreservesOperationFailureAndCanBeRetried() async throws {
        let marker = try temporaryMarker()
        defer { try? FileManager.default.removeItem(at: marker) }
        let prepared = AgentPreparedOneShotPrompt(command: ShellCommand(executable: "missing")) {
            if FileManager.default.fileExists(atPath: marker.path) { throw CocoaError(.fileWriteNoPermission) }
        }
        let runner = DefaultAgentOneShotPromptRunner(adapters: [PreparedPromptAdapter(prepared: prepared)], shellRunner: FakeShellRunner())
        do {
            _ = try await runner.generate(request)
            XCTFail("Expected cleanup error")
        } catch AgentOneShotPromptError.cleanupFailed(_, let reason, let original) {
            XCTAssertFalse(reason.isEmpty)
            XCTAssertTrue(original?.contains("127") == true)
        }
        try FileManager.default.removeItem(at: marker)
        XCTAssertNoThrow(try prepared.cleanup())
        XCTAssertNoThrow(try prepared.cleanup())
    }

    private var request: AgentOneShotPromptRequest {
        AgentOneShotPromptRequest(harnessId: .claude, workingDirectory: URL(fileURLWithPath: "/tmp"), prompt: "Review")
    }

    private func temporaryMarker() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("prepared-marker-\(UUID().uuidString)")
        try Data().write(to: path)
        return path
    }
}

private struct PreparedPromptAdapter: AgentHarnessAdapter {
    let definition = ClaudeHarnessDefinition.definition
    let prepared: AgentPreparedOneShotPrompt

    func prepareOneShotPrompt(request: AgentOneShotPromptRequest) async throws -> AgentPreparedOneShotPrompt { prepared }
    func makeLaunchConfiguration(spawnConfig: AgentSpawnConfig, resumedSession: AgentSessionRecord?) async throws -> AgentLaunchConfiguration {
        throw AgentCLIError.invalidInput("Unused")
    }
    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] { [] }
    func encodeInput(_ input: AgentInput) async throws -> Data { Data() }
}

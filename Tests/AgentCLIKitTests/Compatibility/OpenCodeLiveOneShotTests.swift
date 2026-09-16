import XCTest

@testable import AgentCLIKit

final class OpenCodeLiveOneShotTests: XCTestCase {
    func testLiveCancellationTerminatesTheProcessBeforeDeletingItsProfile() async throws {
        let fixture = try await OpenCodeLiveFixture.start()
        do {
            let shell = OpenCodeLiveOneShotShell()
            let runner = DefaultAgentOneShotPromptRunner(adapters: [fixture.adapter], shellRunner: shell)
            let task = Task {
                try await runner.generate(AgentOneShotPromptRequest(
                    harnessId: .opencode, workingDirectory: fixture.workspace, prompt: "FIXTURE_STEER", model: "fixture/fixture", timeout: 20
                ))
            }
            try await fixture.waitForSlowRequest()
            task.cancel()
            do { _ = try await task.value; XCTFail("Expected cancellation") } catch AgentOneShotPromptError.cancelled { }
            let recordedCommand = await shell.command
            let command = try XCTUnwrap(recordedCommand)
            let existed = await shell.profileExistedAtTermination
            XCTAssertTrue(existed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(command.environment["HOME"])))
            try await fixture.release()
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    func testLiveOneShotFinalTextExcludesTheReadToolPreambleAndOutsideReadIsDenied() async throws {
        let fixture = try await OpenCodeLiveFixture.start()
        do {
            try Data("Packet evidence".utf8).write(to: fixture.workspace.appendingPathComponent("packet.txt"))
            try Data("OUTSIDE-MUST-NOT-BE-READ".utf8).write(to: fixture.root.appendingPathComponent("outside.txt"))
            let runner = DefaultAgentOneShotPromptRunner(adapters: [fixture.adapter])
            let read = try await runner.generate(AgentOneShotPromptRequest(
                harnessId: .opencode, workingDirectory: fixture.workspace, prompt: "FIXTURE_READ", model: "fixture/fixture", timeout: 20
            ))
            XCTAssertEqual(read.text, "Fixture read complete.")
            XCTAssertTrue(read.stdout.contains("Packet evidence"))
            let denied = try await runner.generate(AgentOneShotPromptRequest(
                harnessId: .opencode, workingDirectory: fixture.workspace, prompt: "FIXTURE_OUTSIDE", model: "fixture/fixture", timeout: 20
            ))
            XCTAssertEqual(denied.text, "Fixture outside complete.")
            XCTAssertFalse(denied.stdout.contains("OUTSIDE-MUST-NOT-BE-READ"))
            let tools = try denied.stdout.split(whereSeparator: \.isNewline).map {
                try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
            }.filter { $0[oc: "type"] == .string("tool_use") }
            XCTAssertEqual(tools.first?[oc: "part"]?[oc: "state"]?[oc: "status"], .string("error"))
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    func testLiveOneShotUsesOnlyReadToolsAndRemovesItsSession() async throws {
        let fixture = try await OpenCodeLiveFixture.start()
        do {
            let sentinel = fixture.root.appendingPathComponent("custom-tool-executed")
            let tools = fixture.workspace.appendingPathComponent(".opencode/tools")
            try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
            let encodedPath = try XCTUnwrap(String(data: JSONEncoder().encode(sentinel.path), encoding: .utf8))
            let script = "import {writeFileSync} from 'node:fs'; writeFileSync(\(encodedPath), 'bad');"
            try Data(script.utf8).write(to: tools.appendingPathComponent("danger.ts"))
            let request = AgentOneShotPromptRequest(
                harnessId: .opencode, workingDirectory: fixture.workspace, prompt: "FIXTURE_TEXT", model: "fixture/fixture", timeout: 20
            )
            let prepared = try await fixture.adapter.prepareOneShotPrompt(request: request)
            let home = try XCTUnwrap(prepared.command.environment["HOME"])
            let result: ShellCommandResult
            do {
                result = try await ProcessShellRunner().run(prepared.command)
            } catch {
                try? prepared.cleanup()
                throw error
            }
            XCTAssertEqual(result.exitCode, 0, result.stderr)
            let text = try await fixture.adapter.finalOneShotPromptText(stdout: result.stdout, stderr: result.stderr, request: request)
            XCTAssertEqual(text, "Fixture text complete.")
            let database = try XCTUnwrap(prepared.command.environment["OPENCODE_DB"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: database))
            try prepared.cleanup()
            XCTAssertFalse(FileManager.default.fileExists(atPath: database))
            XCTAssertFalse(FileManager.default.fileExists(atPath: home))
            XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
            let stateURL = try XCTUnwrap(fixture.endpoints["stateURL"].flatMap(URL.init(string:)))
            let (data, _) = try await URLSession.shared.data(from: stateURL)
            let state = try JSONDecoder().decode(JSONValue.self, from: data)
            XCTAssertEqual(state[oc: "toolNames"], .array([.string("glob"), .string("grep"), .string("read")]))
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }
}

private actor OpenCodeLiveOneShotShell: ShellRunning {
    var command: ShellCommand?
    var profileExistedAtTermination = false

    func run(_ command: ShellCommand) async throws -> ShellCommandResult {
        self.command = command
        defer { profileExistedAtTermination = FileManager.default.fileExists(atPath: command.environment["HOME"] ?? "") }
        return try await ProcessShellRunner().run(command)
    }
}

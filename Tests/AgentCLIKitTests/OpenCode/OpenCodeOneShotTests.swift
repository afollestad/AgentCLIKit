import XCTest

@testable import AgentCLIKit

final class OpenCodeOneShotTests: XCTestCase {
    func testPreparationReplacesEnvironmentAndOwnsDisposableNativeState() async throws {
        let fixture = try OpenCodeOneShotTestFixture()
        defer { fixture.cleanup() }
        let shell = OpenCodeOneShotTestShell()
        let prepared = try await fixture.adapter(shell: shell).prepareOneShotPrompt(request: fixture.request(effort: " native "))
        let command = prepared.command
        XCTAssertFalse(command.inheritsEnvironment)
        XCTAssertEqual(command.standardInput, "Review this packet")
        XCTAssertEqual(Array(command.arguments.suffix(2)), ["--variant", " native "])
        XCTAssertNil(command.environment["NODE_OPTIONS"])
        XCTAssertNil(command.environment["OPENCODE_PERMISSION"])
        XCTAssertNil(command.environment["OPENCODE_AUTH_CONTENT"])
        XCTAssertNil(command.environment["OTHER_PROVIDER_API_KEY"])
        XCTAssertEqual(command.environment["OPENCODE_PURE"], "true")
        XCTAssertEqual(command.environment["OPENCODE_DISABLE_PROJECT_CONFIG"], "true")
        let profile = try XCTUnwrap(command.environment["HOME"]).deletingLastPathComponent
        XCTAssertNotEqual(command.environment["HOME"], fixture.root.path)
        XCTAssertGreaterThan(try XCTUnwrap(prepared.executionDeadline).timeIntervalSinceNow, 1_190)
        let configPath = try XCTUnwrap(command.environment["OPENCODE_CONFIG"])
        let config = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: configPath)))
        XCTAssertEqual(config[oc: "permission"]?[oc: "*"], .string("deny"))
        XCTAssertEqual(config[oc: "permission"]?[oc: "read"], .string("allow"))
        XCTAssertEqual(config[oc: "permission"]?[oc: "external_directory"]?[oc: "*"], .string("deny"))
        XCTAssertEqual(config[oc: "lsp"], .bool(false))
        XCTAssertEqual(config[oc: "plugin"], .array([]))
        let probes = await shell.commands
        XCTAssertEqual(probes.map(\.arguments), [["--version"], ["models", "fixture", "--verbose"]])
        XCTAssertTrue(probes.allSatisfy { !$0.inheritsEnvironment && $0.environment == command.environment })
        try prepared.cleanup()
        try prepared.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile))
    }

    func testNativeDefaultAndEmptyVariantRemainDistinct() async throws {
        let fixture = try OpenCodeOneShotTestFixture()
        defer { fixture.cleanup() }
        let adapter = fixture.adapter(shell: OpenCodeOneShotTestShell())
        let native = try await adapter.prepareOneShotPrompt(request: fixture.request())
        defer { try? native.cleanup() }
        XCTAssertFalse(native.command.arguments.contains("--variant"))
        let empty = try await adapter.prepareOneShotPrompt(request: fixture.request(effort: ""))
        defer { try? empty.cleanup() }
        XCTAssertEqual(Array(empty.command.arguments.suffix(2)), ["--variant", ""])
    }

    func testVerboseCatalogPreservesUnicodeNewlinesInsideJSONStrings() throws {
        let expected = "First\u{0085}Second\u{2028}Third\u{2029}Fourth"
        for separator in ["\n", "\r\n"] {
            let output = "fixture/model\n{\n  \"name\": \"\(expected)\"\n}\n".replacingOccurrences(of: "\n", with: separator)
            let metadata = try OpenCodeHarnessAdapter.oneShotModelMetadata(output, model: "fixture/model")
            XCTAssertEqual(metadata?[oc: "name"], .string(expected))
        }
    }

    func testUnknownVariantCleansTheProfileWithoutLaunchingPrompt() async throws {
        let fixture = try OpenCodeOneShotTestFixture()
        defer { fixture.cleanup() }
        let shell = OpenCodeOneShotTestShell()
        do {
            _ = try await fixture.adapter(shell: shell).prepareOneShotPrompt(request: fixture.request(effort: "unknown"))
            XCTFail("Expected exact variant validation")
        } catch is AgentCLIError { }
        let commands = await shell.commands
        let home = try XCTUnwrap(commands.first?.environment["HOME"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home))
        XCTAssertFalse(commands.contains { $0.arguments.first == "run" })
    }

    func testCommandOnlyAPIAndCustomArgumentsCannotBypassPreparation() async throws {
        let fixture = try OpenCodeOneShotTestFixture()
        defer { fixture.cleanup() }
        let adapter = fixture.adapter(shell: OpenCodeOneShotTestShell())
        do {
            _ = try await adapter.makeOneShotPromptCommand(request: fixture.request())
            XCTFail("Expected resource-aware preparation requirement")
        } catch AgentOneShotPromptError.unsupportedHarness(.opencode) { }
        do {
            _ = try await adapter.prepareOneShotPrompt(request: fixture.request(arguments: ["--attach", "http://localhost:4096"]))
            XCTFail("Expected arbitrary flags to be rejected")
        } catch is AgentCLIError { }
    }

    func testRunnerCleansAfterSuccessAndEveryFailureBoundary() async throws {
        let fixture = try OpenCodeOneShotTestFixture()
        defer { fixture.cleanup() }
        for mode in OpenCodeOneShotTestShell.Mode.allCases {
            let shell = OpenCodeOneShotTestShell(mode: mode)
            let runner = DefaultAgentOneShotPromptRunner(adapters: [fixture.adapter(shell: shell)], shellRunner: shell)
            do {
                let result = try await runner.generate(fixture.request(timeout: mode == .timeout ? 0.01 : nil))
                XCTAssertEqual(mode, .success)
                XCTAssertEqual(result.text, "Final answer")
            } catch {
                XCTAssertNotEqual(mode, .success, "\(error)")
            }
            let commands = await shell.commands
            let home = try XCTUnwrap(commands.first?.environment["HOME"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: home), "Profile remains after \(mode)")
            let terminatedBeforeCleanup = await shell.profileExistedAtTermination
            XCTAssertTrue(terminatedBeforeCleanup, "Cleanup raced the process for \(mode)")
        }
    }
}

struct OpenCodeOneShotTestFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-one-shot-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func adapter(shell: any ShellRunning) -> OpenCodeHarnessAdapter {
        OpenCodeHarnessAdapter(configuration: .init(
            executablePath: "/fixture/opencode", environment: [
                "HOME": root.path, "XDG_CONFIG_HOME": root.path, "XDG_DATA_HOME": root.path,
                "OPENCODE_CONFIG": root.appendingPathComponent("absent.json").path, "OPENCODE_CONFIG_DIR": root.path,
                "OPENCODE_CONFIG_CONTENT": #"{"provider":{"fixture":{"npm":"@ai-sdk/openai-compatible"}}}"#,
                "OPENCODE_AUTH_CONTENT": "{}", "NODE_OPTIONS": "--import malicious.js", "OPENCODE_PERMISSION": #"{"*":"allow"}"#,
                "OTHER_PROVIDER_API_KEY": "must-not-copy"
            ], oneShotShellRunner: shell
        ))
    }

    func request(effort: String? = nil, arguments: [String] = [], timeout: TimeInterval? = nil) -> AgentOneShotPromptRequest {
        AgentOneShotPromptRequest(
            harnessId: .opencode, workingDirectory: root, prompt: "Review this packet", arguments: arguments,
            model: "fixture/model", effort: effort, timeout: timeout
        )
    }
}

actor OpenCodeOneShotTestShell: ShellRunning {
    enum Mode: CaseIterable { case success, launchFailure, exitFailure, malformed, cancellation, timeout }
    let mode: Mode
    var commands: [ShellCommand] = []
    var profileExistedAtTermination = false

    init(mode: Mode = .success) { self.mode = mode }

    func run(_ command: ShellCommand) async throws -> ShellCommandResult {
        commands.append(command)
        if command.arguments == ["--version"] { return ShellCommandResult(exitCode: 0, stdout: "1.18.31\n", stderr: "") }
        if command.arguments.first == "models" {
            return ShellCommandResult(exitCode: 0, stdout: "fixture/model\n{\n  \"variants\": {\" native \": {}, \"\": {}}\n}\n", stderr: "")
        }
        defer { profileExistedAtTermination = FileManager.default.fileExists(atPath: command.environment["HOME"] ?? "") }
        switch mode {
        case .launchFailure: throw CocoaError(.executableNotLoadable)
        case .cancellation: throw CancellationError()
        case .timeout: try await Task.sleep(for: .seconds(30))
        case .exitFailure: return ShellCommandResult(exitCode: 1, stdout: "", stderr: "Native failure")
        case .malformed: return ShellCommandResult(exitCode: 0, stdout: "not JSON", stderr: "")
        case .success: break
        }
        return ShellCommandResult(exitCode: 0, stdout: OpenCodeOneShotOutputTests.completedOutput, stderr: "")
    }
}

private extension String {
    var deletingLastPathComponent: String { URL(fileURLWithPath: self).deletingLastPathComponent().path }
}

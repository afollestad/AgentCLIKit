import Foundation
import XCTest

@testable import AgentCLIKit

final class CodexFeatureSupportTests: XCTestCase {
    func testFeatureListParserFindsFastModeFromTextRows() {
        let output = """
        Name                                    Stage              Enabled
        fast_mode                               stable             false
        goals                                   stable             true
        namespace_tools                         stable             true
        other_feature                           experimental       true
        """

        XCTAssertEqual(DefaultCodexFeatureSupportChecker.parseFeatureNames(from: output), [
            "fast_mode",
            "goals",
            "namespace_tools",
            "other_feature"
        ])
    }

    func testFeatureCheckerUsesAvailabilityPathEnvironmentAndCodexHome() async throws {
        let codexHome = URL(fileURLWithPath: "/tmp/codex-home", isDirectory: true)
        let environment = ["CODEX_TEST": "1", "CODEX_HOME": codexHome.path]
        let versionCommand = ShellCommand(
            executable: "/opt/homebrew/bin/codex",
            arguments: ["--version"],
            environment: environment
        )
        let featuresCommand = ShellCommand(
            executable: "/opt/homebrew/bin/codex",
            arguments: ["features", "list"],
            environment: environment
        )
        let shellRunner = FakeShellRunner(results: [
            versionCommand: .success(ShellCommandResult(exitCode: 0, stdout: "codex-cli 1.0\n", stderr: "")),
            featuresCommand: .success(ShellCommandResult(
                exitCode: 0,
                stdout: "fast_mode stable false\ngoals stable true\n",
                stderr: ""
            ))
        ])
        let checker = DefaultCodexFeatureSupportChecker(shellRunner: shellRunner)
        let configuration = CodexProviderAdapter.Configuration(
            codexHomeDirectory: codexHome,
            environment: ["CODEX_TEST": "1"],
            featureSupportChecker: checker,
            executableResolver: RecordingExecutableResolver(path: nil)
        )

        let supportsFastMode = await checker.supportsFastMode(
            configuration: configuration,
            availability: AgentProviderAvailability(
                providerId: .codex,
                executablePath: "/opt/homebrew/bin/codex"
            )
        )
        let supportsGoalMode = await checker.supportsGoalMode(
            configuration: configuration,
            availability: AgentProviderAvailability(
                providerId: .codex,
                executablePath: "/opt/homebrew/bin/codex"
            )
        )

        XCTAssertTrue(supportsFastMode)
        XCTAssertTrue(supportsGoalMode)
        let commands = await shellRunner.commands()
        XCTAssertEqual(commands, [versionCommand, featuresCommand, versionCommand])
    }

    func testFeatureCheckerCachesByExecutableAndVersion() async throws {
        let versionCommand = ShellCommand(executable: "/opt/homebrew/bin/codex", arguments: ["--version"])
        let featuresCommand = ShellCommand(executable: "/opt/homebrew/bin/codex", arguments: ["features", "list"])
        let shellRunner = FakeShellRunner(results: [
            versionCommand: .success(ShellCommandResult(exitCode: 0, stdout: "codex-cli 1.0\n", stderr: "")),
            featuresCommand: .success(ShellCommandResult(exitCode: 0, stdout: "fast_mode stable true\ngoals stable true\n", stderr: ""))
        ])
        let checker = DefaultCodexFeatureSupportChecker(shellRunner: shellRunner, cacheTimeToLive: 60)
        let configuration = CodexProviderAdapter.Configuration(
            executablePath: "/opt/homebrew/bin/codex",
            featureSupportChecker: checker
        )

        let firstResult = await checker.supportsFastMode(configuration: configuration, availability: nil)
        let secondResult = await checker.supportsGoalMode(configuration: configuration, availability: nil)
        let commands = await shellRunner.commands()

        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(commands, [versionCommand, featuresCommand, versionCommand])
    }

    func testFeatureCheckerInvalidatesCacheWhenPathChanges() async throws {
        let firstVersionCommand = ShellCommand(executable: "/opt/codex-a", arguments: ["--version"])
        let firstFeaturesCommand = ShellCommand(executable: "/opt/codex-a", arguments: ["features", "list"])
        let secondVersionCommand = ShellCommand(executable: "/opt/codex-b", arguments: ["--version"])
        let secondFeaturesCommand = ShellCommand(executable: "/opt/codex-b", arguments: ["features", "list"])
        let shellRunner = FakeShellRunner(results: [
            firstVersionCommand: .success(ShellCommandResult(exitCode: 0, stdout: "codex-cli 1.0\n", stderr: "")),
            firstFeaturesCommand: .success(ShellCommandResult(exitCode: 0, stdout: "other_feature stable true\n", stderr: "")),
            secondVersionCommand: .success(ShellCommandResult(exitCode: 0, stdout: "codex-cli 1.0\n", stderr: "")),
            secondFeaturesCommand: .success(ShellCommandResult(exitCode: 0, stdout: "fast_mode stable true\n", stderr: ""))
        ])
        let checker = DefaultCodexFeatureSupportChecker(shellRunner: shellRunner, cacheTimeToLive: 60)
        let firstConfiguration = CodexProviderAdapter.Configuration(
            executablePath: "/opt/codex-a",
            featureSupportChecker: checker
        )
        let secondConfiguration = CodexProviderAdapter.Configuration(
            executablePath: "/opt/codex-b",
            featureSupportChecker: checker
        )

        let firstResult = await checker.supportsFastMode(configuration: firstConfiguration, availability: nil)
        let secondResult = await checker.supportsFastMode(configuration: secondConfiguration, availability: nil)
        let commands = await shellRunner.commands()

        XCTAssertFalse(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(commands, [
            firstVersionCommand,
            firstFeaturesCommand,
            secondVersionCommand,
            secondFeaturesCommand
        ])
    }

    func testFeatureCheckerInvalidatesCacheWhenVersionChanges() async throws {
        let versionCommand = ShellCommand(executable: "/opt/homebrew/bin/codex", arguments: ["--version"])
        let featuresCommand = ShellCommand(executable: "/opt/homebrew/bin/codex", arguments: ["features", "list"])
        let shellRunner = SequentialShellRunner(responses: [
            ShellCommandResult(exitCode: 0, stdout: "codex-cli 1.0\n", stderr: ""),
            ShellCommandResult(exitCode: 0, stdout: "other_feature stable true\n", stderr: ""),
            ShellCommandResult(exitCode: 0, stdout: "codex-cli 2.0\n", stderr: ""),
            ShellCommandResult(exitCode: 0, stdout: "fast_mode stable true\n", stderr: "")
        ])
        let checker = DefaultCodexFeatureSupportChecker(shellRunner: shellRunner, cacheTimeToLive: 60)
        let configuration = CodexProviderAdapter.Configuration(
            executablePath: "/opt/homebrew/bin/codex",
            featureSupportChecker: checker
        )

        let firstResult = await checker.supportsFastMode(configuration: configuration, availability: nil)
        let secondResult = await checker.supportsFastMode(configuration: configuration, availability: nil)
        let commands = await shellRunner.commands()

        XCTAssertFalse(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(commands, [
            versionCommand,
            featuresCommand,
            versionCommand,
            featuresCommand
        ])
    }

    func testFeatureCheckerDegradesUnsupportedOnProbeTimeout() async {
        let checker = DefaultCodexFeatureSupportChecker(
            shellRunner: SlowShellRunner(),
            cacheTimeToLive: 60
        )
        let configuration = CodexProviderAdapter.Configuration(
            executablePath: "/opt/homebrew/bin/codex",
            probeTimeout: 0.001,
            featureSupportChecker: checker
        )

        let supportsFastMode = await checker.supportsFastMode(configuration: configuration, availability: nil)

        XCTAssertFalse(supportsFastMode)
    }

    func testCodexProviderCapabilitySourceOverlaysSpeedSupportOnlyForCodex() async {
        let checker = FixedCodexFeatureSupportChecker(supportsFastMode: true, supportsGoalMode: true)
        let configuration = CodexProviderAdapter.Configuration(featureSupportChecker: checker)
        let source = CodexProviderCapabilitySource(configuration: configuration)

        let codexCapabilities = await source.capabilities(
            for: CodexProviderDefinition.definition,
            availability: AgentProviderAvailability(providerId: .codex, executablePath: "/usr/bin/codex")
        )
        let claudeCapabilities = await source.capabilities(
            for: ClaudeProviderDefinition.definition,
            availability: AgentProviderAvailability(providerId: .claude, executablePath: "/usr/bin/claude")
        )

        XCTAssertTrue(codexCapabilities.supportsSpeedMode)
        XCTAssertTrue(codexCapabilities.supportsGoalMode)
        XCTAssertTrue(codexCapabilities.supportsExistingSessionGoalStart)
        XCTAssertEqual(codexCapabilities.supportedGoalActions, [.pause, .resume, .delete])
        XCTAssertFalse(claudeCapabilities.supportsSpeedMode)
    }

    func testCodexProviderCapabilitySourceDisablesGoalModeWhenFeatureProbeDoesNotSupportIt() async {
        let checker = FixedCodexFeatureSupportChecker(supportsFastMode: false, supportsGoalMode: false)
        let configuration = CodexProviderAdapter.Configuration(featureSupportChecker: checker)
        let source = CodexProviderCapabilitySource(configuration: configuration)

        let capabilities = await source.capabilities(
            for: CodexProviderDefinition.definition,
            availability: AgentProviderAvailability(providerId: .codex, executablePath: "/usr/bin/codex")
        )

        XCTAssertFalse(capabilities.supportsGoalMode)
        XCTAssertFalse(capabilities.supportsExistingSessionGoalStart)
        XCTAssertEqual(capabilities.supportedGoalActions, [])
    }
}

private struct SlowShellRunner: ShellRunning {
    func run(_ command: ShellCommand) async throws -> ShellCommandResult {
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return ShellCommandResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private actor SequentialShellRunner: ShellRunning {
    private var responses: [ShellCommandResult]
    private var recordedCommands: [ShellCommand] = []

    init(responses: [ShellCommandResult]) {
        self.responses = responses
    }

    func run(_ command: ShellCommand) async throws -> ShellCommandResult {
        recordedCommands.append(command)
        guard !responses.isEmpty else {
            return ShellCommandResult(exitCode: 127, stdout: "", stderr: "command not found")
        }
        return responses.removeFirst()
    }

    func commands() -> [ShellCommand] {
        recordedCommands
    }
}

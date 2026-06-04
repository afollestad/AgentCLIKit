import XCTest

@testable import AgentCLIKit

final class AgentProviderTests: XCTestCase {
    func testProviderIDIncludesCodex() throws {
        let decoded = try JSONDecoder().decode(AgentProviderID.self, from: Data(#""codex""#.utf8))

        XCTAssertEqual(AgentProviderID.allCases, [.claude, .codex])
        XCTAssertEqual(decoded, .codex)
        XCTAssertEqual(decoded.rawValue, "codex")
    }

    func testDefaultAdapterSetExposesBuiltInRuntimeDefinitions() {
        let adapterSet = AgentProviderAdapterSet.default

        XCTAssertEqual(adapterSet.definitions.map(\.id), [.claude, .codex])
        XCTAssertEqual(adapterSet.definitions.map(\.displayName), ["Claude", "Codex"])
    }

    func testBuiltInProviderDefinitionsIncludeClaudeAndCodexWithoutRuntimeAdapters() {
        let definitions = AgentProviderRegistry.builtInDefinitions

        XCTAssertEqual(definitions.map(\.id), [.claude, .codex])
        XCTAssertEqual(definitions.map(\.displayName), ["Claude", "Codex"])
        XCTAssertTrue(definitions[0].capabilities.supportsHooks)
        XCTAssertFalse(definitions[0].capabilities.supportsSessionArchiving)
        XCTAssertFalse(definitions[0].capabilities.supportsSessionUnarchiving)
        XCTAssertFalse(definitions[1].capabilities.supportsHooks)
        XCTAssertTrue(definitions[1].capabilities.supportsModelListing)
        XCTAssertTrue(definitions[1].capabilities.supportsSessionArchiving)
        XCTAssertTrue(definitions[1].capabilities.supportsSessionUnarchiving)
        XCTAssertEqual(definitions[1].supportedPermissionModes?.map(\.value), ["untrusted", "on-request", "never"])
    }

    func testAdapterSetOverridesBuiltInAdapters() {
        let adapterSet = AgentProviderAdapterSet(overriding: [
            FakeProviderAdapter(command: AgentLaunchConfiguration(executable: "/usr/bin/true"))
        ])

        XCTAssertEqual(adapterSet.adapters.count, 2)
        XCTAssertEqual(adapterSet.definitions.first?.id, .claude)
        XCTAssertEqual(adapterSet.definitions.first?.displayName, "Fake")
        XCTAssertEqual(adapterSet.definitions.last?.id, .codex)
    }

    func testDefaultAdapterSetAcceptsClaudeConfiguration() async throws {
        let adapterSet = AgentProviderAdapterSet.default(
            claude: ClaudeProviderAdapter.Configuration(executablePath: "/custom/claude", enableHooks: false)
        )
        let adapter = try XCTUnwrap(adapterSet.adapters.first)

        let launch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(providerId: .claude, workingDirectory: URL(fileURLWithPath: "/tmp/project")),
            resumedSession: nil
        )

        XCTAssertEqual(launch.executable, "/custom/claude")
    }

    func testRegistryReturnsRegisteredDefinitions() async {
        let registry = AgentProviderRegistry.builtIn()

        let definitions = await registry.allDefinitions()

        XCTAssertEqual(definitions.map(\.id), [.claude, .codex])
    }

    func testRegistryUsesLastDuplicateDefinition() async {
        let registry = AgentProviderRegistry(definitions: [
            AgentProviderDefinition(id: .claude, displayName: "Old", executableNames: ["old"]),
            AgentProviderDefinition(id: .claude, displayName: "New", executableNames: ["new"])
        ])

        let definition = await registry.definition(for: .claude)

        XCTAssertEqual(definition?.displayName, "New")
        XCTAssertEqual(definition?.executableNames, ["new"])
    }

    func testProviderDefinitionRoundTripsLaunchMetadataAndDefaultsLegacyFields() throws {
        let definition = AgentProviderDefinition(
            id: .claude,
            displayName: "Claude",
            executableNames: ["claude"],
            versionArguments: ["version"],
            capabilities: AgentProviderCapabilities(
                supportsMidTurnSteering: true,
                supportsToolEvents: true,
                supportsGroupedToolOutput: true,
                supportsPlanMode: true,
                supportsTaskLists: true,
                supportsSubagents: true,
                supportsPromptRequests: true,
                supportsContextWindow: true,
                supportsNativeThreadFork: true,
                supportsPermissionPrompts: true,
                supportsModelListing: true,
                supportsSessionArchiving: true,
                supportsSessionUnarchiving: true
            ),
            supportedPermissionModes: [
                AgentProviderOption(value: "plan", label: "Plan", description: "Read-only planning.")
            ],
            supportedEffortLevels: ["low", "high"]
        )

        let data = try JSONEncoder().encode(definition)
        let decoded = try JSONDecoder().decode(AgentProviderDefinition.self, from: data)
        let legacy = try JSONDecoder().decode(
            AgentProviderDefinition.self,
            from: Data(#"{"id":"claude","displayName":"Claude","executableNames":["claude"]}"#.utf8)
        )

        XCTAssertEqual(decoded, definition)
        XCTAssertEqual(decoded.versionArguments, ["version"])
        XCTAssertEqual(decoded.supportedPermissionModes?.map(\.value), ["plan"])
        XCTAssertEqual(decoded.supportedEffortLevels, ["low", "high"])
        XCTAssertTrue(decoded.capabilities.supportsToolEvents)
        XCTAssertTrue(decoded.capabilities.supportsPromptRequests)
        XCTAssertTrue(decoded.capabilities.supportsModelListing)
        XCTAssertTrue(decoded.capabilities.supportsSessionArchiving)
        XCTAssertTrue(decoded.capabilities.supportsSessionUnarchiving)
        assertLegacyProviderDefinitionDefaults(legacy)
    }

    func testLaunchConfigurationRoundTripsProviderSessionIdAndDefaultsLegacyFields() throws {
        let launch = AgentLaunchConfiguration(
            executable: "/usr/bin/env",
            arguments: ["claude"],
            sessionContinuity: .fresh,
            providerSessionId: "provider-session",
            includesSpawnArguments: true
        )

        let data = try JSONEncoder().encode(launch)
        let decoded = try JSONDecoder().decode(AgentLaunchConfiguration.self, from: data)
        let legacy = try JSONDecoder().decode(
            AgentLaunchConfiguration.self,
            from: Data(#"{"executable":"/usr/bin/env","arguments":["claude"]}"#.utf8)
        )

        XCTAssertEqual(decoded, launch)
        XCTAssertEqual(decoded.providerSessionId, "provider-session")
        XCTAssertNil(legacy.providerSessionId)
        XCTAssertNil(legacy.sessionContinuity)
        XCTAssertFalse(legacy.includesSpawnArguments)
    }

    func testDetectorFindsFirstAvailableExecutableAndVersion() async {
        let whichClaude = ShellCommand(executable: "/usr/bin/env", arguments: ["which", "claude"])
        let versionClaude = ShellCommand(executable: "/opt/homebrew/bin/claude", arguments: ["--version"])
        let shell = FakeShellRunner(results: [
            whichClaude: .success(ShellCommandResult(exitCode: 0, stdout: "/opt/homebrew/bin/claude\n", stderr: "")),
            versionClaude: .success(ShellCommandResult(exitCode: 0, stdout: "Claude Code 1.2.3\n", stderr: ""))
        ])
        let detector = AgentProviderDetector(shellRunner: shell)

        let availability = await detector.availability(
            for: AgentProviderDefinition(id: .claude, displayName: "Claude", executableNames: ["claude"])
        )

        XCTAssertTrue(availability.isAvailable)
        XCTAssertEqual(availability.executablePath, "/opt/homebrew/bin/claude")
        XCTAssertEqual(availability.versionDescription, "Claude Code 1.2.3")
    }

    func testDetectorReturnsUnavailableWhenNoExecutableIsFound() async {
        let shell = FakeShellRunner()
        let detector = AgentProviderDetector(shellRunner: shell)

        let availability = await detector.availability(
            for: AgentProviderDefinition(id: .claude, displayName: "Missing", executableNames: ["missing"])
        )

        XCTAssertFalse(availability.isAvailable)
        XCTAssertNil(availability.executablePath)
    }

    func testDetectorAcceptsExecutablePathWithoutWhichLookup() async throws {
        let executableURL = try makeTemporaryExecutable()
        let versionCommand = ShellCommand(executable: executableURL.path, arguments: ["--version"])
        let shell = FakeShellRunner(results: [
            versionCommand: .success(ShellCommandResult(exitCode: 0, stdout: "Agent 1.0\n", stderr: ""))
        ])
        let detector = AgentProviderDetector(shellRunner: shell)

        let availability = await detector.availability(
            for: AgentProviderDefinition(id: .claude, displayName: "Agent", executableNames: [executableURL.path])
        )

        XCTAssertEqual(availability.executablePath, executableURL.path)
        XCTAssertEqual(availability.versionDescription, "Agent 1.0")
        let whichLookup = ShellCommand(executable: "/usr/bin/env", arguments: ["which", executableURL.path])
        let commands = await shell.commands()
        XCTAssertFalse(commands.contains(whichLookup))
    }

    func testDetectorResolvesTildeExecutablePath() async throws {
        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executableURL = try makeTemporaryExecutable(directory: homeDirectory.appendingPathComponent("bin", isDirectory: true))
        let versionCommand = ShellCommand(executable: executableURL.path, arguments: ["--version"])
        let shell = FakeShellRunner(results: [
            versionCommand: .success(ShellCommandResult(exitCode: 0, stdout: "Agent 1.0\n", stderr: ""))
        ])
        let detector = AgentProviderDetector(shellRunner: shell, homeDirectory: homeDirectory)

        let availability = await detector.availability(
            for: AgentProviderDefinition(id: .claude, displayName: "Agent", executableNames: ["~/bin/agent"])
        )

        XCTAssertEqual(availability.executablePath, executableURL.path)
    }

    func testDetectorFallsBackToLoginShellLookup() async throws {
        let executableURL = try makeTemporaryExecutable()
        let loginShell = ShellCommand(
            executable: "/bin/sh",
            arguments: ["-lc", "resolved=$(command -v 'claude') && printf '%s%s\\n' '__AGENTCLIKIT_EXECUTABLE_PATH__' \"$resolved\""]
        )
        let versionClaude = ShellCommand(executable: executableURL.path, arguments: ["version"])
        let shell = FakeShellRunner(results: [
            loginShell: .success(ShellCommandResult(exitCode: 0, stdout: "__AGENTCLIKIT_EXECUTABLE_PATH__\(executableURL.path)\n", stderr: "")),
            versionClaude: .success(ShellCommandResult(exitCode: 0, stdout: "Claude Code 1.2.3\n", stderr: ""))
        ])
        let detector = AgentProviderDetector(
            shellRunner: shell,
            fallbackExecutableDirectories: [],
            loginShellExecutablePaths: ["/bin/sh"]
        )

        let availability = await detector.availability(
            for: AgentProviderDefinition(
                id: .claude,
                displayName: "Claude",
                executableNames: ["claude"],
                versionArguments: ["version"]
            )
        )

        XCTAssertEqual(availability.executablePath, executableURL.path)
        XCTAssertEqual(availability.versionDescription, "Claude Code 1.2.3")
    }

    func testDetectorUsesFallbackExecutableDirectories() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executableURL = try makeTemporaryExecutable(directory: directory)
        let versionCommand = ShellCommand(executable: executableURL.path, arguments: ["--version"])
        let shell = FakeShellRunner(results: [
            versionCommand: .success(ShellCommandResult(exitCode: 0, stdout: "Agent 1.0\n", stderr: ""))
        ])
        let detector = AgentProviderDetector(
            shellRunner: shell,
            fallbackExecutableDirectories: [directory.path],
            loginShellExecutablePaths: []
        )

        let availability = await detector.availability(
            for: AgentProviderDefinition(id: .claude, displayName: "Agent", executableNames: ["agent"])
        )

        XCTAssertEqual(availability.executablePath, executableURL.path)
        XCTAssertEqual(availability.versionDescription, "Agent 1.0")
    }

    private func makeTemporaryExecutable(
        directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executableURL = directory.appendingPathComponent("agent")
        try "#!/bin/sh\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        return executableURL
    }

    private func assertLegacyProviderDefinitionDefaults(_ legacy: AgentProviderDefinition) {
        XCTAssertEqual(legacy.versionArguments, ["--version"])
        XCTAssertFalse(legacy.capabilities.supportsMidTurnSteering)
        XCTAssertFalse(legacy.capabilities.supportsToolEvents)
        XCTAssertFalse(legacy.capabilities.supportsGroupedToolOutput)
        XCTAssertFalse(legacy.capabilities.supportsPlanMode)
        XCTAssertFalse(legacy.capabilities.supportsTaskLists)
        XCTAssertFalse(legacy.capabilities.supportsSubagents)
        XCTAssertFalse(legacy.capabilities.supportsPromptRequests)
        XCTAssertFalse(legacy.capabilities.supportsContextWindow)
        XCTAssertFalse(legacy.capabilities.supportsNativeThreadFork)
        XCTAssertFalse(legacy.capabilities.supportsPermissionPrompts)
        XCTAssertFalse(legacy.capabilities.supportsModelListing)
        XCTAssertFalse(legacy.capabilities.supportsSessionArchiving)
        XCTAssertFalse(legacy.capabilities.supportsSessionUnarchiving)
        XCTAssertNil(legacy.supportedPermissionModes)
        XCTAssertNil(legacy.supportedEffortLevels)
    }
}

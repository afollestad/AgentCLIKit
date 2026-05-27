import XCTest

@testable import AgentCLIKit

final class AgentProviderTests: XCTestCase {
    func testRegistryReturnsRegisteredDefinitions() async {
        let registry = AgentProviderRegistry(definitions: [
            AgentProviderDefinition(id: .claude, displayName: "Claude", executableNames: ["claude"])
        ])

        let definitions = await registry.allDefinitions()

        XCTAssertEqual(definitions.map(\.id), [.claude])
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
            capabilities: AgentProviderCapabilities(supportsMidTurnSteering: true),
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
        XCTAssertEqual(decoded.supportedPermissionModes?.map(\.value), ["plan"])
        XCTAssertEqual(decoded.supportedEffortLevels, ["low", "high"])
        XCTAssertFalse(legacy.capabilities.supportsMidTurnSteering)
        XCTAssertNil(legacy.supportedPermissionModes)
        XCTAssertNil(legacy.supportedEffortLevels)
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

    private func makeTemporaryExecutable() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executableURL = directory.appendingPathComponent("agent")
        try "#!/bin/sh\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        return executableURL
    }
}

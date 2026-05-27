import XCTest

@testable import AgentCLIKit

final class ClaudeProviderAdapterTests: XCTestCase {
    func testLaunchConfigurationUsesResumeModelEffortAndInitialPrompt() async throws {
        let adapter = ClaudeProviderAdapter(
            executablePath: "/opt/homebrew/bin/claude",
            sessionFileExists: { _ in true }
        )
        let session = AgentSessionRecord(
            conversationId: "conversation",
            providerId: .claude,
            providerSessionId: "session-id",
            generation: 1
        )
        let config = AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            arguments: ["--dangerously-skip-permissions"],
            environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude-config"],
            model: "sonnet",
            effort: "high",
            permissionMode: "acceptEdits",
            initialPrompt: "Continue"
        )

        let launch = try await adapter.makeLaunchConfiguration(spawnConfig: config, resumedSession: session)

        XCTAssertEqual(launch.executable, "/opt/homebrew/bin/claude")
        XCTAssertEqual(launch.arguments, [
            "-p",
            "--output-format",
            "stream-json",
            "--input-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-mode",
            "acceptEdits",
            "--model",
            "sonnet",
            "--effort",
            "high",
            "--resume",
            "session-id",
            "--dangerously-skip-permissions",
            "Continue"
        ])
        XCTAssertEqual(launch.environment, ["CLAUDE_CONFIG_DIR": "/tmp/claude-config"])
        XCTAssertEqual(launch.workingDirectory?.path, "/tmp/project")
        XCTAssertEqual(launch.sessionContinuity, .resumed)
        XCTAssertTrue(launch.includesSpawnArguments)
    }

    func testClaudeDefinitionExposesHostLaunchMetadata() {
        let definition = ClaudeProviderAdapter().definition

        XCTAssertTrue(definition.capabilities.supportsMidTurnSteering)
        XCTAssertEqual(definition.supportedPermissionModes?.map(\.value), ["default", "plan", "acceptEdits", "auto"])
        XCTAssertEqual(definition.supportedEffortLevels, ["low", "medium", "high", "xhigh", "max"])
    }

    func testLaunchConfigurationFallsBackToSessionIDWhenResumeArtifactIsMissing() async throws {
        let adapter = ClaudeProviderAdapter(
            executablePath: "/opt/homebrew/bin/claude",
            sessionFileExists: { _ in false }
        )
        let session = AgentSessionRecord(
            conversationId: "conversation",
            providerId: .claude,
            providerSessionId: "session-id",
            generation: 1
        )

        let launch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(providerId: .claude, workingDirectory: URL(fileURLWithPath: "/tmp/project")),
            resumedSession: session
        )

        XCTAssertFalse(launch.arguments.contains("--resume"))
        XCTAssertEqual(Array(launch.arguments.suffix(2)), ["--session-id", "session-id"])
        XCTAssertEqual(launch.sessionContinuity, .restartedFresh)
    }

    func testDefaultLaunchUsesEnvClaudeFallback() async throws {
        let adapter = ClaudeProviderAdapter()

        let launch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(providerId: .claude, workingDirectory: URL(fileURLWithPath: "/tmp")),
            resumedSession: nil
        )

        XCTAssertEqual(launch.executable, "/usr/bin/env")
        XCTAssertEqual(Array(launch.arguments.prefix(8)), [
            "claude",
            "-p",
            "--output-format",
            "stream-json",
            "--input-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages"
        ])
        XCTAssertEqual(launch.sessionContinuity, .fresh)
    }

    func testPrepareLaunchSkipsHooksWhenPermissionModeDisablesHooks() async throws {
        let adapter = ClaudeProviderAdapter()
        let launch = AgentLaunchConfiguration(executable: "/usr/bin/env", arguments: ["claude"])
        let prepared = try await adapter.prepareLaunchConfiguration(
            launch,
            spawnConfig: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: URL(fileURLWithPath: "/tmp"),
                permissionMode: "auto"
            ),
            conversationId: "conversation",
            processToken: UUID()
        )

        XCTAssertEqual(prepared, launch)
    }

    func testInputEncoderWritesStreamJSONLine() throws {
        let data = try ClaudeInputEncoder().encode(.userMessage(AgentMessageInput(text: "Hello")))
        let json = try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any]
        let message = json?["message"] as? [String: Any]
        let content = message?["content"] as? [[String: Any]]

        XCTAssertEqual(json?["type"] as? String, "user")
        XCTAssertEqual(message?["role"] as? String, "user")
        XCTAssertEqual(content?.first?["text"] as? String, "Hello")
        XCTAssertEqual(data.last, 0x0A)
    }

    func testInputEncoderPreservesInteractionResolutionMetadata() throws {
        let resolution = AgentInteractionResolution(
            id: "tool-1",
            outcome: .approved,
            responseText: "approved",
            metadata: ["updated_input": .object(["plan": .string("Ship it")])]
        )

        let data = try ClaudeInputEncoder().encode(.interactionResolution(resolution))
        let json = try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any]
        let encodedResolution = json?["resolution"] as? [String: Any]
        let metadata = encodedResolution?["metadata"] as? [String: Any]
        let updatedInput = metadata?["updated_input"] as? [String: Any]

        XCTAssertEqual(json?["type"] as? String, "interaction_resolution")
        XCTAssertEqual(encodedResolution?["id"] as? String, "tool-1")
        XCTAssertEqual(encodedResolution?["responseText"] as? String, "approved")
        XCTAssertEqual(updatedInput?["plan"] as? String, "Ship it")
    }

    func testSessionIDExtractsClaudeSystemSession() async throws {
        let adapter = ClaudeProviderAdapter()
        let events = try await adapter.decodeStdoutLine(#"{"type":"system","subtype":"init","session_id":"session-123"}"#)

        XCTAssertEqual(events.compactMap { adapter.sessionID(from: $0) }, ["session-123"])
    }

    func testPathEncoderStandardizesFileURL() {
        let encoded = ClaudePathEncoder.encode(URL(fileURLWithPath: "/tmp/../tmp/project"))

        XCTAssertEqual(encoded, "/tmp/project")
    }

    func testPathEncoderBuildsClaudeSessionFileURL() {
        let url = ClaudePathEncoder.sessionFileURL(
            sessionId: "session-id",
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            homeDirectory: URL(fileURLWithPath: "/Users/example")
        )

        XCTAssertEqual(url.path, "/Users/example/.claude/projects/-tmp-project/session-id.jsonl")
    }
}

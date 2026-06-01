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

    func testInitializerAcceptsHostOwnedApprovalPolicyStore() {
        let approvalPolicyStore = ClaudeApprovalPolicyStore()
        let adapter = ClaudeProviderAdapter(approvalPolicyStore: approvalPolicyStore)

        XCTAssertEqual(adapter.definition.id, .claude)
    }

    func testConfigurationInitializerPreservesHookSettings() async throws {
        let adapter = ClaudeProviderAdapter(configuration: ClaudeProviderAdapter.Configuration(enableHooks: false))
        let launch = AgentLaunchConfiguration(executable: "/usr/bin/env", arguments: ["claude"])

        let prepared = try await adapter.prepareLaunchConfiguration(
            launch,
            spawnConfig: AgentSpawnConfig(providerId: .claude, workingDirectory: URL(fileURLWithPath: "/tmp")),
            conversationId: "conversation",
            processToken: UUID()
        )

        XCTAssertEqual(prepared, launch)
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

    func testLaunchConfigurationForksExistingSessionWhenRequested() async throws {
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

        let launch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                forkSession: true
            ),
            resumedSession: session
        )

        XCTAssertEqual(Array(launch.arguments.suffix(3)), ["--resume", "session-id", "--fork-session"])
        XCTAssertEqual(launch.sessionContinuity, .resumed)
    }

    func testLaunchConfigurationDoesNotForkMissingResumeArtifact() async throws {
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
            spawnConfig: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: URL(fileURLWithPath: "/tmp/project"),
                forkSession: true
            ),
            resumedSession: session
        )

        XCTAssertEqual(Array(launch.arguments.suffix(2)), ["--session-id", "session-id"])
        XCTAssertFalse(launch.arguments.contains("--fork-session"))
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

    func testCompletedTaskNotificationReadsResultFromOutputFile() async throws {
        let adapter = ClaudeProviderAdapter()
        let fileURL = try writeTaskOutput("""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Detailed sub-agent result"}]}}
        """)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let events = try await adapter.decodeStdoutLine(Self.completedTaskNotificationLine(outputFile: fileURL.path))

        XCTAssertEqual(events, [
            .task(AgentTaskEvent(
                id: "toolu_agent",
                phase: .notification,
                description: "Agent completed",
                toolUses: 1,
                totalTokens: 200,
                durationMs: 300,
                status: "completed",
                metadata: [
                    "tool_use_id": .string("toolu_agent"),
                    "summary": .string("Agent completed"),
                    "output_file": .string(fileURL.path),
                    "status": .string("completed"),
                    "tool_uses": .number(1),
                    "total_tokens": .number(200),
                    "duration_ms": .number(300),
                    "result": .string("Detailed sub-agent result")
                ]
            ))
        ])
    }

    func testTaskOutputReaderReadsLastAssistantText() throws {
        let fileURL = try writeTaskOutput("""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Draft result"}]}}
        {"type":"user","message":{"role":"user","content":"ignored"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"ignored"},{"type":"text","text":"Final result"}]}}
        """)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        XCTAssertEqual(ClaudeTaskOutputReader().resultText(from: fileURL), "Final result")
    }

    private func writeTaskOutput(_ content: String) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    func testPathEncoderStandardizesFileURL() {
        let encoded = ClaudePathEncoder.encode(URL(fileURLWithPath: "/tmp/../tmp/project"))

        XCTAssertEqual(encoded, "/tmp/project")
    }

    func testPathEncoderStandardizesTildePath() {
        let encoded = ClaudePathEncoder.encode("~/project", homeDirectory: URL(fileURLWithPath: "/Users/example"))

        XCTAssertEqual(encoded, "/Users/example/project")
    }

    func testPathEncoderBuildsClaudeSessionFileURL() {
        let url = ClaudePathEncoder.sessionFileURL(
            sessionId: "session-id",
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            homeDirectory: URL(fileURLWithPath: "/Users/example")
        )

        XCTAssertEqual(url.path, "/Users/example/.claude/projects/-tmp-project/session-id.jsonl")
    }

    func testPathEncoderBuildsClaudeSessionFileURLFromWorkingDirectoryPath() {
        let url = ClaudePathEncoder.sessionFileURL(
            sessionId: "session-id",
            workingDirectoryPath: "~/project",
            homeDirectory: URL(fileURLWithPath: "/Users/example")
        )

        XCTAssertEqual(url.path, "/Users/example/.claude/projects/-Users-example-project/session-id.jsonl")
    }

    func testPathEncoderDetectsExistingClaudeSessionFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workingDirectory = home.appendingPathComponent("project", isDirectory: true)
        let sessionFile = ClaudePathEncoder.sessionFileURL(
            sessionId: "session-id",
            workingDirectory: workingDirectory,
            homeDirectory: home
        )
        try FileManager.default.createDirectory(at: sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: sessionFile)

        XCTAssertTrue(ClaudePathEncoder.sessionFileExists(
            sessionId: "session-id",
            workingDirectory: workingDirectory,
            homeDirectory: home
        ))
        XCTAssertTrue(ClaudePathEncoder.sessionFileExists(
            sessionId: "session-id",
            workingDirectoryPath: workingDirectory.path,
            homeDirectory: home
        ))
    }
}

private extension ClaudeProviderAdapterTests {
    static func completedTaskNotificationLine(outputFile: String) throws -> String {
        let payload: [String: Any] = [
            "type": "system",
            "subtype": "task_notification",
            "tool_use_id": "toolu_agent",
            "status": "completed",
            "output_file": outputFile,
            "summary": "Agent completed",
            "usage": [
                "tool_uses": 1,
                "total_tokens": 200,
                "duration_ms": 300
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}

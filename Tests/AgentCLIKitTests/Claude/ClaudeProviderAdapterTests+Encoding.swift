import XCTest

@testable import AgentCLIKit

/// Executable resolution, launch preparation, input encoding, and path encoding.
extension ClaudeProviderAdapterTests {
    func testDefaultLaunchUsesEnvClaudeFallback() async throws {
        let resolver = RecordingExecutableResolver(path: nil)
        let adapter = ClaudeProviderAdapter(configuration: ClaudeProviderAdapter.Configuration(executableResolver: resolver))

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

    func testDefaultLaunchUsesResolvedClaudeExecutable() async throws {
        let resolver = RecordingExecutableResolver(path: "/Users/test/.local/bin/claude")
        let adapter = ClaudeProviderAdapter(configuration: ClaudeProviderAdapter.Configuration(executableResolver: resolver))

        let launch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(providerId: .claude, workingDirectory: URL(fileURLWithPath: "/tmp")),
            resumedSession: nil
        )
        let requestedDefinitions = await resolver.requestedDefinitions

        XCTAssertEqual(requestedDefinitions.map(\.id), [.claude])
        XCTAssertEqual(launch.executable, "/Users/test/.local/bin/claude")
        XCTAssertEqual(Array(launch.arguments.prefix(7)), [
            "-p",
            "--output-format",
            "stream-json",
            "--input-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages"
        ])
        XCTAssertFalse(launch.arguments.contains("claude"))
    }

    func testExactClaudeExecutableBypassesResolver() async throws {
        let resolver = RecordingExecutableResolver(path: "/Users/test/.local/bin/claude")
        let adapter = ClaudeProviderAdapter(configuration: ClaudeProviderAdapter.Configuration(
            executablePath: "/opt/homebrew/bin/claude",
            executableResolver: resolver
        ))

        let launch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(providerId: .claude, workingDirectory: URL(fileURLWithPath: "/tmp")),
            resumedSession: nil
        )
        let requestedDefinitions = await resolver.requestedDefinitions

        XCTAssertEqual(requestedDefinitions.map(\.id), [])
        XCTAssertEqual(launch.executable, "/opt/homebrew/bin/claude")
        XCTAssertFalse(launch.arguments.contains("claude"))
    }

    func testPrepareLaunchKeepsCompactHooksWhenPermissionModeDisablesApprovalHooks() async throws {
        let hookSupportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hookSupportDirectory) }
        let adapter = ClaudeProviderAdapter(hookSupportDirectory: hookSupportDirectory)
        addTeardownBlock {
            await adapter.shutdownProviderResources()
        }
        let launch = AgentLaunchConfiguration(executable: "/usr/bin/env", arguments: ["claude"])
        let processToken = UUID()

        let prepared = try await adapter.prepareLaunchConfiguration(
            launch,
            spawnConfig: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: URL(fileURLWithPath: "/tmp"),
                permissionMode: "auto"
            ),
            conversationId: "conversation",
            processToken: processToken
        )
        let settingsIndex = try XCTUnwrap(prepared.arguments.firstIndex(of: "--settings"))
        let settingsPath = prepared.arguments[settingsIndex + 1]
        let settingsData = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: settingsData) as? [String: Any])
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])

        XCTAssertNotEqual(prepared, launch)
        XCTAssertNil(hooks["PreToolUse"])
        XCTAssertNotNil(hooks["PreCompact"])
        XCTAssertNotNil(hooks["PostCompact"])
    }

    func testPrepareLaunchFallsBackWithoutHookSettingsWhenHookPrepFails() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let hookSupportDirectory = temporaryDirectory.appendingPathComponent("not-a-directory", isDirectory: true)
        try Data("file".utf8).write(to: hookSupportDirectory)
        let adapter = ClaudeProviderAdapter(hookSupportDirectory: hookSupportDirectory)
        addTeardownBlock {
            await adapter.shutdownProviderResources()
        }
        let launch = AgentLaunchConfiguration(
            executable: "/usr/bin/env",
            arguments: ["claude", "Prompt"],
            environment: ["EXISTING": "1"],
            workingDirectory: temporaryDirectory,
            includesSpawnArguments: true
        )

        let prepared = try await adapter.prepareLaunchConfiguration(
            launch,
            spawnConfig: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: temporaryDirectory,
                permissionMode: "default",
                initialPrompt: "Prompt"
            ),
            conversationId: "conversation",
            processToken: UUID()
        )

        XCTAssertEqual(prepared, launch)
        XCTAssertFalse(prepared.arguments.contains("--settings"))
        XCTAssertNil(prepared.environment["AGENTCLIKIT_CLAUDE_HOOK_TOKEN"])
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

    func testInputEncoderRejectsAttachments() throws {
        let input = AgentInput.userMessage(AgentMessageInput(
            text: "Look at this",
            attachments: [
                .localImage(id: "image-1", fileURL: URL(fileURLWithPath: "/tmp/screenshot.png"))
            ]
        ))

        XCTAssertThrowsError(try ClaudeInputEncoder().encode(input)) { error in
            guard case let AgentCLIError.unsupportedInputAttachment(providerId, attachmentId, type, reason) = error else {
                XCTFail("Expected unsupportedInputAttachment, got \(error).")
                return
            }
            XCTAssertEqual(providerId, .claude)
            XCTAssertEqual(attachmentId, "image-1")
            XCTAssertEqual(type, "localImage")
            XCTAssertEqual(reason, "Claude input transport is text-only.")
        }
    }

    func testInputEncoderEncodesInteractionResolutionAsEmptyData() throws {
        // The Claude CLI has no stdin message type for interaction resolutions; they resolve via hooks instead.
        let resolution = AgentInteractionResolution(
            id: "tool-1",
            outcome: .approved,
            responseText: "approved",
            metadata: ["updated_input": .object(["plan": .string("Ship it")])]
        )

        let data = try ClaudeInputEncoder().encode(.interactionResolution(resolution))

        XCTAssertTrue(data.isEmpty)
    }

    func testSessionIDExtractsClaudeSystemSession() async throws {
        let adapter = ClaudeProviderAdapter()
        let events = try await adapter.decodeStdoutLine(#"{"type":"system","subtype":"init","session_id":"session-123"}"#)

        XCTAssertEqual(events.compactMap { adapter.sessionID(from: $0) }, ["session-123"])
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

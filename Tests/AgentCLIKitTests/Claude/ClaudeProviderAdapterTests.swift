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
            "--dangerously-skip-permissions"
        ])
        XCTAssertTrue(launch.sendsInitialPromptOverStdin)
        XCTAssertEqual(launch.environment, ["CLAUDE_CONFIG_DIR": "/tmp/claude-config"])
        XCTAssertEqual(launch.workingDirectory?.path, "/tmp/project")
        XCTAssertEqual(launch.sessionContinuity, .resumed)
        XCTAssertTrue(launch.includesSpawnArguments)
    }

    func testClaudeDefinitionExposesHostLaunchMetadata() {
        let definition = ClaudeProviderAdapter().definition

        XCTAssertTrue(definition.capabilities.supportsMidTurnSteering)
        XCTAssertTrue(definition.capabilities.supportsModelOptions)
        XCTAssertTrue(definition.capabilities.supportsPlanMode)
        XCTAssertEqual(definition.supportedPermissionModes, ClaudeProviderDefinition.definition.supportedPermissionModes)
    }

    func testAcceptedSteeringInputEventMarksRuntimeAcceptedInput() {
        let adapter = ClaudeProviderAdapter(configuration: ClaudeProviderAdapter.Configuration(enableHooks: false))
        let message = AgentMessageInput(
            text: "Use option B",
            metadata: [
                AgentSteeringMetadata.isSteering: .bool(true),
                AgentSteeringMetadata.inputId: .string("local-message-1")
            ]
        )

        let event = adapter.acceptedSteeringInputEvent(for: message, context: Self.inputContext(isTurnActive: true))

        XCTAssertEqual(event, .message(AgentMessageEvent(
            role: .user,
            text: "Use option B",
            metadata: [
                AgentSteeringMetadata.isSteering: .bool(true),
                AgentSteeringMetadata.inputId: .string("local-message-1"),
                AgentSteeringMetadata.signal: .string(AgentSteeringMetadata.signalRuntimeInputAccepted)
            ]
        )))
    }

    func testAcceptedSteeringInputEventRequiresInputId() {
        let adapter = ClaudeProviderAdapter(configuration: ClaudeProviderAdapter.Configuration(enableHooks: false))
        let message = AgentMessageInput(
            text: "Use option B",
            metadata: [AgentSteeringMetadata.isSteering: .bool(true)]
        )

        XCTAssertNil(adapter.acceptedSteeringInputEvent(for: message, context: Self.inputContext(isTurnActive: true)))
    }

    func testInitialGoalTransportEncodesGoalSlashCommand() async throws {
        let adapter = ClaudeProviderAdapter(configuration: ClaudeProviderAdapter.Configuration(enableHooks: false))
        let message = AgentMessageInput(
            text: "Ship goal mode",
            metadata: [
                AgentGoalMetadata.isInitialGoalTransport: .bool(true),
                AgentGoalMetadata.objective: .string("Ship goal mode")
            ]
        )

        let data = try await adapter.encodeInput(.userMessage(message), context: Self.inputContext(isTurnActive: true))
        let text = try Self.encodedClaudeText(data)

        XCTAssertEqual(text, "/goal Ship goal mode")
    }

    func testGoalDeleteActionEncodesGoalClearCommand() async throws {
        let adapter = ClaudeProviderAdapter(configuration: ClaudeProviderAdapter.Configuration(enableHooks: false))
        let data = try await adapter.encodeGoalAction(.delete, context: Self.goalActionContext())
        let unwrappedData = try XCTUnwrap(data)
        let text = try Self.encodedClaudeText(unwrappedData)

        XCTAssertEqual(text, "/goal clear")
    }

    func testExistingSessionGoalStartEncodesGoalSlashCommandAndMarksTurnActive() async throws {
        let adapter = ClaudeProviderAdapter(configuration: ClaudeProviderAdapter.Configuration(enableHooks: false))

        let encoded = try await adapter.encodeGoalStart("Ship goal mode", context: Self.goalStartContext())
        let unwrappedEncoded = try XCTUnwrap(encoded)
        let text = try Self.encodedClaudeText(unwrappedEncoded.data)

        XCTAssertEqual(text, "/goal Ship goal mode")
        XCTAssertTrue(unwrappedEncoded.marksTurnActive)
    }

    func testGoalDeleteActionUnavailableWhileTurnIsActive() {
        let adapter = ClaudeProviderAdapter(configuration: ClaudeProviderAdapter.Configuration(enableHooks: false))

        let actions = adapter.availableGoalActions(
            for: AgentGoalSnapshot(objective: "Ship goal mode", status: .active, availableActions: [.delete]),
            context: Self.goalActionContext(isTurnActive: true)
        )

        XCTAssertEqual(actions, [])
    }

    func testUnsupportedGoalActionThrows() async throws {
        let adapter = ClaudeProviderAdapter(configuration: ClaudeProviderAdapter.Configuration(enableHooks: false))

        do {
            _ = try await adapter.encodeGoalAction(.pause, context: Self.goalActionContext())
            XCTFail("Expected unsupported goal action to throw.")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error.code, .unsupportedCapability)
            XCTAssertEqual(error.metadata["provider_id"], .string("claude"))
            XCTAssertEqual(error.metadata["capability"], .string("goal pause"))
        }
    }

    func testLaunchConfigurationPrioritizesPlanCollaborationModeOverPermissionMode() async throws {
        let adapter = ClaudeProviderAdapter(executablePath: "/opt/homebrew/bin/claude")
        let config = AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            permissionMode: "bypassPermissions",
            collaborationMode: .plan
        )

        let launch = try await adapter.makeLaunchConfiguration(spawnConfig: config, resumedSession: nil)
        let permissionModeIndex = try XCTUnwrap(launch.arguments.firstIndex(of: "--permission-mode"))

        XCTAssertEqual(launch.arguments[permissionModeIndex + 1], "plan")
        XCTAssertFalse(launch.arguments.contains("--allow-dangerously-skip-permissions"))
    }

    func testLaunchConfigurationUsesPermissionModeWhenCollaborationModeIsDefault() async throws {
        let adapter = ClaudeProviderAdapter(executablePath: "/opt/homebrew/bin/claude")
        let config = AgentSpawnConfig(
            providerId: .claude,
            workingDirectory: URL(fileURLWithPath: "/tmp/project"),
            permissionMode: "acceptEdits",
            collaborationMode: .default
        )

        let launch = try await adapter.makeLaunchConfiguration(spawnConfig: config, resumedSession: nil)
        let permissionModeIndex = try XCTUnwrap(launch.arguments.firstIndex(of: "--permission-mode"))

        XCTAssertEqual(launch.arguments[permissionModeIndex + 1], "acceptEdits")
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
        XCTAssertEqual(launch.sessionContinuity, .forked)
    }

    func testLaunchConfigurationForksSourceSessionIntoTargetDirectory() async throws {
        let sourceDirectory = URL(fileURLWithPath: "/tmp/source")
        let targetDirectory = URL(fileURLWithPath: "/tmp/worktree")
        let homeDirectory = URL(fileURLWithPath: "/tmp/home")
        let expectedSourceSessionFile = ClaudePathEncoder.sessionFileURL(
            sessionId: "source-session",
            workingDirectory: sourceDirectory,
            homeDirectory: homeDirectory
        )
        let lookupRecorder = ClaudeSessionLookupRecorder()
        let adapter = ClaudeProviderAdapter(
            executablePath: "/opt/homebrew/bin/claude",
            homeDirectory: homeDirectory,
            sessionFileExists: { url in
                lookupRecorder.append(url)
                return url == expectedSourceSessionFile
            }
        )

        let launch = try await adapter.makeLaunchConfiguration(
            spawnConfig: AgentSpawnConfig(
                providerId: .claude,
                workingDirectory: targetDirectory,
                sessionFork: AgentSessionForkRequest(
                    sourceSessionId: "source-session",
                    sourceWorkingDirectory: sourceDirectory,
                    mode: .worktree
                )
            ),
            resumedSession: nil
        )

        XCTAssertEqual(Array(launch.arguments.suffix(3)), ["--resume", "source-session", "--fork-session"])
        XCTAssertEqual(launch.workingDirectory, targetDirectory)
        XCTAssertEqual(launch.sessionContinuity, .forked)
        XCTAssertEqual(lookupRecorder.urls, [expectedSourceSessionFile])
    }

    func testLaunchConfigurationThrowsWhenForkSourceArtifactIsMissing() async throws {
        let adapter = ClaudeProviderAdapter(
            executablePath: "/opt/homebrew/bin/claude",
            sessionFileExists: { _ in false }
        )

        do {
            _ = try await adapter.makeLaunchConfiguration(
                spawnConfig: AgentSpawnConfig(
                    providerId: .claude,
                    workingDirectory: URL(fileURLWithPath: "/tmp/worktree"),
                    sessionFork: AgentSessionForkRequest(sourceSessionId: "source-session")
                ),
                resumedSession: nil
            )
            XCTFail("Expected missing Claude source artifact to throw.")
        } catch let error as AgentCLIError {
            guard case let .invalidInput(message) = error else {
                XCTFail("Expected invalidInput, got \(error).")
                return
            }
            XCTAssertTrue(message.contains("source session artifact"))
        }
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

}

extension ClaudeProviderAdapterTests {
    static func inputContext(isTurnActive: Bool) -> AgentProviderInputContext {
        AgentProviderInputContext(
            conversationId: "conversation",
            processToken: UUID(),
            providerSessionId: "session-id",
            spawnConfig: AgentSpawnConfig(providerId: .claude, workingDirectory: URL(fileURLWithPath: "/tmp/project")),
            isTurnActive: isTurnActive
        )
    }

    static func goalActionContext() -> AgentProviderGoalActionContext {
        goalActionContext(isTurnActive: false)
    }

    static func goalActionContext(isTurnActive: Bool) -> AgentProviderGoalActionContext {
        AgentProviderGoalActionContext(
            conversationId: "conversation",
            processToken: UUID(),
            providerSessionId: "session-id",
            spawnConfig: AgentSpawnConfig(providerId: .claude, workingDirectory: URL(fileURLWithPath: "/tmp/project")),
            goal: AgentGoalSnapshot(objective: "Ship goal mode", status: .active, availableActions: [.delete]),
            isTurnActive: isTurnActive
        )
    }

    static func goalStartContext() -> AgentProviderGoalStartContext {
        AgentProviderGoalStartContext(
            conversationId: "conversation",
            processToken: UUID(),
            providerSessionId: "session-id",
            spawnConfig: AgentSpawnConfig(providerId: .claude, workingDirectory: URL(fileURLWithPath: "/tmp/project")),
            isTurnActive: false,
            inputAvailability: .available
        )
    }

    static func encodedClaudeText(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        let dictionary = try XCTUnwrap(object as? [String: Any])
        let message = try XCTUnwrap(dictionary["message"] as? [String: Any])
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        let firstContent = try XCTUnwrap(content.first)
        return try XCTUnwrap(firstContent["text"] as? String)
    }

}

private final class ClaudeSessionLookupRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []

    var urls: [URL] {
        lock.withLock {
            recordedURLs
        }
    }

    func append(_ url: URL) {
        lock.withLock {
            recordedURLs.append(url)
        }
    }
}

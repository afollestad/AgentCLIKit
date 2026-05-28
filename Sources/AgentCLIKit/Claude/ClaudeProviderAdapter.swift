import Foundation

/// Claude Code provider adapter.
public struct ClaudeProviderAdapter: AgentProviderAdapter {
    /// Claude provider identifier.
    public static let providerId: AgentProviderID = .claude

    /// Static Claude provider metadata.
    public let definition = AgentProviderDefinition(
        id: ClaudeProviderAdapter.providerId,
        displayName: "Claude",
        executableNames: ["claude"],
        capabilities: AgentProviderCapabilities(
            supportsSessionResume: true,
            supportsHooks: true,
            supportsMCP: true,
            supportsApprovals: true,
            supportsUsage: true,
            supportsMidTurnSteering: true
        ),
        supportedPermissionModes: [
            AgentProviderOption(
                value: "default",
                label: "Default permissions",
                description: "Safe default; denied writes return as tool errors in non-interactive mode."
            ),
            AgentProviderOption(
                value: "plan",
                label: "Plan",
                description: "Read-only exploration and planning."
            ),
            AgentProviderOption(
                value: "acceptEdits",
                label: "Accept edits",
                description: "Auto-accept file edits while keeping stronger checks for other actions."
            ),
            AgentProviderOption(
                value: "auto",
                label: "Automatic",
                description: "Auto-approve most actions with safety checks."
            )
        ],
        supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"]
    )

    private let executablePath: String
    private let decoder: ClaudeStreamDecoder
    private let inputEncoder: ClaudeInputEncoder
    private let homeDirectory: URL
    private let sessionFileExists: @Sendable (URL) -> Bool
    private let hookCoordinator: ClaudeHookCoordinator?

    /// Creates a Claude provider adapter.
    /// - Parameters:
    ///   - executablePath: Claude executable path, or `/usr/bin/env` to resolve `claude` through PATH.
    ///   - decoder: Stream JSON decoder.
    ///   - inputEncoder: Stream JSON input encoder.
    ///   - homeDirectory: Home directory containing `.claude/projects`.
    ///   - sessionFileExists: Predicate used to decide whether a saved Claude session can be resumed.
    ///   - enableHooks: Whether this adapter should manage a Claude hook listener and generated hook settings.
    ///   - interactionStore: Store used for hook-originated pending interactions.
    ///   - approvalPolicyStore: Store used for session and transient hook approvals.
    ///   - hookSupportDirectory: Directory used for generated per-launch Claude hook settings files.
    ///   - hookDecisionProvider: Optional provider that can answer Claude hook decisions while the hook request is still live.
    ///   - hookDecisionTimeout: Maximum live hook decision wait before Claude receives a deferred response.
    public init(
        executablePath: String = "/usr/bin/env",
        decoder: ClaudeStreamDecoder = ClaudeStreamDecoder(),
        inputEncoder: ClaudeInputEncoder = ClaudeInputEncoder(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        sessionFileExists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        enableHooks: Bool = true,
        interactionStore: any AgentInteractionStore = InMemoryAgentInteractionStore(),
        approvalPolicyStore: any ClaudeApprovalPolicyStoring = ClaudeApprovalPolicyStore(),
        hookSupportDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AgentCLIKitClaudeHooks",
            isDirectory: true
        ),
        hookDecisionProvider: (any ClaudeHookDecisionProviding)? = nil,
        hookDecisionTimeout: TimeInterval? = ClaudeHookPolicy.defaultDecisionTimeout
    ) {
        self.executablePath = executablePath
        self.decoder = decoder
        self.inputEncoder = inputEncoder
        self.homeDirectory = homeDirectory
        self.sessionFileExists = sessionFileExists
        if enableHooks {
            let tokenStore = AgentHookTokenStore()
            let hookServer = ClaudeHookServer(
                tokenStore: tokenStore,
                interactionStore: interactionStore,
                approvalPolicyStore: approvalPolicyStore,
                decisionProvider: hookDecisionProvider,
                decisionTimeout: hookDecisionTimeout
            )
            self.hookCoordinator = ClaudeHookCoordinator(
                tokenStore: tokenStore,
                server: hookServer,
                supportDirectory: hookSupportDirectory
            )
        } else {
            self.hookCoordinator = nil
        }
    }

    /// Builds the Claude launch configuration for stream JSON mode.
    public func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        var arguments: [String] = executablePath == "/usr/bin/env" ? ["claude"] : []
        arguments.append(contentsOf: [
            "-p",
            "--output-format",
            "stream-json",
            "--input-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages"
        ])
        if let permissionMode = spawnConfig.permissionMode {
            arguments.append(contentsOf: ["--permission-mode", permissionMode])
        }
        if let model = spawnConfig.model {
            arguments.append(contentsOf: ["--model", model])
        }
        if let effort = spawnConfig.effort {
            arguments.append(contentsOf: ["--effort", effort])
        }
        var sessionContinuity: AgentSessionContinuity = resumedSession == nil ? .fresh : .resumed
        if let sessionId = resumedSession?.providerSessionId {
            let sessionFileURL = ClaudePathEncoder.sessionFileURL(
                sessionId: sessionId,
                workingDirectory: spawnConfig.workingDirectory,
                homeDirectory: homeDirectory
            )
            let canResume = sessionFileExists(sessionFileURL)
            sessionContinuity = canResume ? .resumed : .restartedFresh
            var sessionArguments = canResume ? ["--resume", sessionId.rawValue] : ["--session-id", sessionId.rawValue]
            if canResume, spawnConfig.forkSession {
                sessionArguments.append("--fork-session")
            }
            arguments.append(contentsOf: sessionArguments)
        }
        arguments.append(contentsOf: spawnConfig.arguments)
        if let initialPrompt = spawnConfig.initialPrompt {
            arguments.append(initialPrompt)
        }
        return AgentLaunchConfiguration(
            executable: executablePath,
            arguments: arguments,
            environment: spawnConfig.environment,
            workingDirectory: spawnConfig.workingDirectory,
            sessionContinuity: sessionContinuity,
            includesSpawnArguments: true
        )
    }

    /// Decodes one Claude stream JSON stdout line.
    public func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        try decoder.decodeLine(line)
    }

    /// Extracts Claude's resumable session identifier from system events.
    public func sessionID(from event: AgentEvent) -> AgentSessionID? {
        guard
            case let .diagnostic(diagnostic) = event,
            case let .string(sessionId)? = diagnostic.metadata["session_id"],
            !sessionId.isEmpty
        else {
            return nil
        }
        return AgentSessionID(rawValue: sessionId)
    }

    /// Encodes host input as Claude stream JSON stdin.
    public func encodeInput(_ input: AgentInput) async throws -> Data {
        try inputEncoder.encode(input)
    }

    /// Adds generated Claude hook settings and bearer token environment for this launch.
    public func prepareLaunchConfiguration(
        _ launch: AgentLaunchConfiguration,
        spawnConfig: AgentSpawnConfig,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async throws -> AgentLaunchConfiguration {
        guard let hookCoordinator,
              ClaudeHookPolicy.shouldEnableHooks(permissionMode: spawnConfig.permissionMode) else {
            return launch
        }
        do {
            let hooks = try await hookCoordinator.prepareLaunch(
                conversationId: conversationId,
                processToken: processToken
            )
            var arguments = launch.arguments
            let prompt = spawnConfig.initialPrompt
            if let prompt, arguments.last == prompt {
                arguments.removeLast()
            }
            arguments.append(contentsOf: hooks.arguments)
            if let prompt {
                arguments.append(prompt)
            }
            return AgentLaunchConfiguration(
                executable: launch.executable,
                arguments: arguments,
                environment: launch.environment.merging(hooks.environment) { _, new in new },
                workingDirectory: launch.workingDirectory,
                sessionContinuity: launch.sessionContinuity,
                includesSpawnArguments: launch.includesSpawnArguments
            )
        } catch {
            await hookCoordinator.invalidate(processToken: processToken)
            throw error
        }
    }

    /// Invalidates the hook token associated with a finished or superseded Claude process.
    public func processDidTerminate(processToken: UUID) async {
        await hookCoordinator?.invalidate(processToken: processToken)
    }

    /// Updates provider-owned hook state from streamed permission-mode status.
    public func permissionModeDidChange(_ mode: String?, conversationId: AgentConversationID) async {
        await hookCoordinator?.updatePermissionMode(mode, for: conversationId)
    }

    /// Stops the shared Claude hook listener and invalidates active launch tokens.
    public func shutdownProviderResources() async {
        await hookCoordinator?.shutdown()
    }
}

/// Helper for paths passed to Claude metadata.
public enum ClaudePathEncoder {
    /// Encodes a file URL as a standardized path string.
    public static func encode(_ url: URL) -> String {
        AgentPathHelpers.canonicalPath(url)
    }

    /// Encodes a path that may include `~` as a canonical path string.
    public static func encode(_ path: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        AgentPathHelpers.canonicalPath(path, homeDirectory: homeDirectory)
    }

    /// Encodes a canonical project path into Claude's project-directory name.
    public static func projectDirectoryName(forCanonicalPath path: String) -> String {
        path.unicodeScalars.map { scalar in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" {
                String(scalar)
            } else {
                "-"
            }
        }
        .joined()
    }

    /// Returns Claude's JSONL session file URL for a session and working directory.
    public static func sessionFileURL(sessionId: AgentSessionID, workingDirectory: URL, homeDirectory: URL) -> URL {
        let encodedDirectory = projectDirectoryName(forCanonicalPath: encode(workingDirectory))
        return homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(encodedDirectory, isDirectory: true)
            .appendingPathComponent("\(sessionId.rawValue).jsonl")
    }

    /// Returns Claude's JSONL session file URL for a session and working directory path.
    public static func sessionFileURL(
        sessionId: AgentSessionID,
        workingDirectoryPath: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let encodedDirectory = projectDirectoryName(forCanonicalPath: encode(workingDirectoryPath, homeDirectory: homeDirectory))
        return homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(encodedDirectory, isDirectory: true)
            .appendingPathComponent("\(sessionId.rawValue).jsonl")
    }

    /// Returns whether Claude's JSONL session file exists for a session and working directory.
    public static func sessionFileExists(
        sessionId: AgentSessionID,
        workingDirectory: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(atPath: sessionFileURL(
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            homeDirectory: homeDirectory
        ).path)
    }

    /// Returns whether Claude's JSONL session file exists for a session and working directory path.
    public static func sessionFileExists(
        sessionId: AgentSessionID,
        workingDirectoryPath: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(atPath: sessionFileURL(
            sessionId: sessionId,
            workingDirectoryPath: workingDirectoryPath,
            homeDirectory: homeDirectory
        ).path)
    }
}

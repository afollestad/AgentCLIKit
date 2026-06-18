import Foundation

/// Claude Code provider adapter.
public struct ClaudeProviderAdapter: AgentProviderAdapter {
    /// Claude provider identifier.
    public static let providerId = ClaudeProviderDefinition.providerId

    /// Configuration used to create a Claude provider adapter.
    public struct Configuration: Sendable {
        /// Claude executable path, or `/usr/bin/env` to resolve `claude` through PATH.
        public let executablePath: String
        /// Resolver used when `executablePath` is `/usr/bin/env`.
        public let executableResolver: any AgentProviderExecutableResolving
        /// Stream JSON decoder.
        public let decoder: ClaudeStreamDecoder
        /// Stream JSON input encoder.
        public let inputEncoder: ClaudeInputEncoder
        /// Home directory containing `.claude/projects`.
        public let homeDirectory: URL
        /// Predicate used to decide whether a saved Claude session can be resumed.
        public let sessionFileExists: @Sendable (URL) -> Bool
        /// Whether this adapter should manage a Claude hook listener and generated hook settings.
        public let enableHooks: Bool
        /// Store used for hook-originated pending interactions.
        public let interactionStore: any AgentInteractionStore
        /// Store used for session and transient hook approvals.
        public let approvalPolicyStore: any ClaudeApprovalPolicyStoring
        /// Directory used for generated per-launch Claude hook settings files.
        public let hookSupportDirectory: URL
        /// Optional provider that can answer Claude hook decisions while the hook request is still live.
        public let hookDecisionProvider: (any ClaudeHookDecisionProviding)?
        /// Maximum live hook decision wait before Claude receives a deferred response.
        public let hookDecisionTimeout: TimeInterval?

        /// Creates a Claude adapter configuration.
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
        ///   - executableResolver: Resolver used when `executablePath` is `/usr/bin/env`.
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
            hookDecisionTimeout: TimeInterval? = ClaudeHookPolicy.defaultDecisionTimeout,
            executableResolver: any AgentProviderExecutableResolving = DefaultAgentProviderExecutableResolver()
        ) {
            self.executablePath = executablePath
            self.executableResolver = executableResolver
            self.decoder = decoder
            self.inputEncoder = inputEncoder
            self.homeDirectory = homeDirectory
            self.sessionFileExists = sessionFileExists
            self.enableHooks = enableHooks
            self.interactionStore = interactionStore
            self.approvalPolicyStore = approvalPolicyStore
            self.hookSupportDirectory = hookSupportDirectory
            self.hookDecisionProvider = hookDecisionProvider
            self.hookDecisionTimeout = hookDecisionTimeout
        }
    }

    /// Static Claude provider metadata.
    public let definition = ClaudeProviderDefinition.definition

    private let executablePath: String
    private let executableResolver: any AgentProviderExecutableResolving
    private let decoder: ClaudeStreamDecoder
    private let inputEncoder: ClaudeInputEncoder
    private let homeDirectory: URL
    private let sessionFileExists: @Sendable (URL) -> Bool
    private let taskOutputReader = ClaudeTaskOutputReader()
    private let compactionTracker: ClaudeContextCompactionTracker
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
    ///   - executableResolver: Resolver used when `executablePath` is `/usr/bin/env`.
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
        hookDecisionTimeout: TimeInterval? = ClaudeHookPolicy.defaultDecisionTimeout,
        executableResolver: any AgentProviderExecutableResolving = DefaultAgentProviderExecutableResolver()
    ) {
        self.init(configuration: Configuration(
            executablePath: executablePath,
            decoder: decoder,
            inputEncoder: inputEncoder,
            homeDirectory: homeDirectory,
            sessionFileExists: sessionFileExists,
            enableHooks: enableHooks,
            interactionStore: interactionStore,
            approvalPolicyStore: approvalPolicyStore,
            hookSupportDirectory: hookSupportDirectory,
            hookDecisionProvider: hookDecisionProvider,
            hookDecisionTimeout: hookDecisionTimeout,
            executableResolver: executableResolver
        ))
    }

    /// Creates a Claude provider adapter with a reusable configuration value.
    public init(configuration: Configuration) {
        self.executablePath = configuration.executablePath
        self.executableResolver = configuration.executableResolver
        self.decoder = configuration.decoder
        self.inputEncoder = configuration.inputEncoder
        self.homeDirectory = configuration.homeDirectory
        self.sessionFileExists = configuration.sessionFileExists
        self.compactionTracker = ClaudeContextCompactionTracker()
        if configuration.enableHooks {
            let tokenStore = AgentHookTokenStore()
            let hookServer = ClaudeHookServer(
                tokenStore: tokenStore,
                interactionStore: configuration.interactionStore,
                approvalPolicyStore: configuration.approvalPolicyStore,
                decisionProvider: configuration.hookDecisionProvider,
                decisionTimeout: configuration.hookDecisionTimeout,
                compactionTracker: compactionTracker
            )
            self.hookCoordinator = ClaudeHookCoordinator(
                tokenStore: tokenStore,
                server: hookServer,
                supportDirectory: configuration.hookSupportDirectory
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
        if spawnConfig.speedMode == .fast {
            // Claude's fast-like `--bare` mode disables hooks, so reject Fast instead of mapping it to launch flags.
            throw AgentCLIError.unsupportedCapability(providerId: Self.providerId, capability: "fast mode")
        }
        let launchExecutable = await resolvedLaunchExecutable()
        var arguments = launchExecutable.arguments
        arguments.append(contentsOf: [
            "-p",
            "--output-format",
            "stream-json",
            "--input-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages"
        ])
        if let permissionMode = effectivePermissionMode(for: spawnConfig) {
            if ClaudePermissionModes.requiresDangerousModeUnlock(permissionMode) {
                arguments.append("--allow-dangerously-skip-permissions")
            }
            arguments.append(contentsOf: ["--permission-mode", permissionMode])
        }
        arguments.append(contentsOf: ["--model", ClaudeModelAliases.normalizedModel(spawnConfig.model)])
        if let effort = ClaudeModelAliases.normalizedEffort(spawnConfig.effort, model: spawnConfig.model) {
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
        return AgentLaunchConfiguration(
            executable: launchExecutable.executable,
            arguments: arguments,
            environment: spawnConfig.environment,
            workingDirectory: spawnConfig.workingDirectory,
            sessionContinuity: sessionContinuity,
            includesSpawnArguments: true,
            sendsInitialPromptOverStdin: true
        )
    }

    private func resolvedLaunchExecutable() async -> (executable: String, arguments: [String]) {
        guard executablePath == "/usr/bin/env" else {
            return (executablePath, [])
        }
        if let resolvedPath = await executableResolver.resolvedExecutablePath(for: definition) {
            return (resolvedPath, [])
        }
        return (executablePath, ["claude"])
    }

    /// Decodes one Claude stream JSON stdout line.
    public func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        try decoder.decodeLine(line).map(enrichCompletedTaskOutput)
    }

    /// Decodes one Claude stream JSON stdout line with process context.
    public func decodeStdoutLine(_ line: String, context: AgentProviderOutputContext) async throws -> [AgentEvent] {
        let events = try decoder.decodeLine(line).map(enrichCompletedTaskOutput)
        return await compactionTracker.normalize(events, context: context)
    }

    /// Extracts Claude's resumable session identifier from provider events.
    public func sessionID(from event: AgentEvent) -> AgentSessionID? {
        switch event {
        case let .diagnostic(diagnostic):
            guard case let .string(sessionId)? = diagnostic.metadata["session_id"],
                  !sessionId.isEmpty else {
                return nil
            }
            return AgentSessionID(rawValue: sessionId)
        case let .contextCompaction(compaction):
            guard let sessionId = compaction.metadata.stringValue("session_id") ?? compaction.metadata.stringValue("sessionId"),
                  !sessionId.isEmpty else {
                return nil
            }
            return AgentSessionID(rawValue: sessionId)
        default:
            return nil
        }
    }

    private func enrichCompletedTaskOutput(_ event: AgentEvent) -> AgentEvent {
        guard case let .subAgent(subAgent) = event,
              subAgent.phase == .terminal,
              subAgent.result == nil,
              let outputFile = subAgent.metadata.stringValue("output_file"),
              let result = taskOutputReader.resultText(from: URL(fileURLWithPath: outputFile))?.trimmingCharacters(in: .whitespacesAndNewlines),
              !result.isEmpty else {
            return event
        }

        var metadata = subAgent.metadata
        metadata["result"] = .string(result)
        return .subAgent(AgentSubAgentEvent(
            id: subAgent.id,
            phase: subAgent.phase,
            description: subAgent.description,
            prompt: subAgent.prompt,
            agentType: subAgent.agentType,
            input: subAgent.input,
            lastToolName: subAgent.lastToolName,
            status: subAgent.status,
            result: result,
            toolUses: subAgent.toolUses,
            totalTokens: subAgent.totalTokens,
            durationMs: subAgent.durationMs,
            parentToolUseId: subAgent.parentToolUseId,
            callerAgent: subAgent.callerAgent,
            parentSessionId: subAgent.parentSessionId,
            childSessionIds: subAgent.childSessionIds,
            metadata: metadata
        ))
    }

    /// Encodes host input as Claude stream JSON stdin.
    public func encodeInput(_ input: AgentInput) async throws -> Data {
        try inputEncoder.encode(input)
    }

    /// Emits a steering marker once Claude stdin accepts a marked mid-turn user input.
    public func acceptedSteeringInputEvent(for message: AgentMessageInput, context: AgentProviderInputContext) -> AgentEvent? {
        guard message.metadata[AgentSteeringMetadata.isSteering] == .bool(true),
              message.metadata.nonEmptyStringValue(AgentSteeringMetadata.inputId) != nil else {
            return nil
        }
        var metadata = message.metadata
        metadata[AgentSteeringMetadata.signal] = .string(AgentSteeringMetadata.signalRuntimeInputAccepted)
        return .message(AgentMessageEvent(role: .user, text: message.text, metadata: metadata))
    }

    /// Returns Claude hook runtime events for the active launch.
    public func runtimeEvents(context: AgentProviderRuntimeContext) async -> AsyncStream<AgentProviderRuntimeEvent> {
        guard let hookCoordinator else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        return await hookCoordinator.runtimeEvents(context: context)
    }

    /// Adds generated Claude hook settings and bearer token environment for this launch when hook setup succeeds.
    public func prepareLaunchConfiguration(
        _ launch: AgentLaunchConfiguration,
        spawnConfig: AgentSpawnConfig,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async throws -> AgentLaunchConfiguration {
        guard let hookCoordinator else {
            return launch
        }
        do {
            let hooks = try await hookCoordinator.prepareLaunch(
                conversationId: conversationId,
                processToken: processToken,
                permissionMode: effectivePermissionMode(for: spawnConfig),
                workingDirectory: launch.workingDirectory ?? spawnConfig.workingDirectory,
                homeDirectory: homeDirectory
            )
            var arguments = launch.arguments
            arguments.append(contentsOf: hooks.arguments)
            return AgentLaunchConfiguration(
                executable: launch.executable,
                arguments: arguments,
                environment: launch.environment.merging(hooks.environment) { _, new in new },
                workingDirectory: launch.workingDirectory,
                sessionContinuity: launch.sessionContinuity,
                includesSpawnArguments: launch.includesSpawnArguments,
                sendsInitialPromptOverStdin: launch.sendsInitialPromptOverStdin
            )
        } catch {
            await hookCoordinator.invalidate(processToken: processToken)
            return launch
        }
    }

    /// Invalidates the hook token associated with a finished or superseded Claude process.
    public func processDidTerminate(processToken: UUID) async {
        await hookCoordinator?.invalidate(processToken: processToken)
        await compactionTracker.reset(processToken: processToken)
    }

    /// Updates provider-owned hook state from streamed permission-mode status.
    public func permissionModeDidChange(_ mode: String?, conversationId: AgentConversationID) async {
        await hookCoordinator?.updatePermissionMode(mode.map(ClaudePermissionModes.canonicalHostMode), for: conversationId)
    }

    /// Stops the shared Claude hook listener and invalidates active launch tokens.
    public func shutdownProviderResources() async {
        await hookCoordinator?.shutdown()
    }

    private func effectivePermissionMode(for spawnConfig: AgentSpawnConfig) -> String? {
        guard spawnConfig.collaborationMode != .plan else {
            return ClaudePermissionModes.plan
        }
        return spawnConfig.permissionMode.map(ClaudePermissionModes.canonicalHostMode)
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

private extension [String: JSONValue] {
    func stringValue(_ key: String) -> String? {
        guard case let .string(value)? = self[key] else {
            return nil
        }
        return value
    }

    func nonEmptyStringValue(_ key: String) -> String? {
        guard let value = stringValue(key), !value.isEmpty else {
            return nil
        }
        return value
    }
}

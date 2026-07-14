import Foundation

/// Codex provider adapter backed by Codex App Server.
public struct CodexProviderAdapter: AgentProviderAdapter {
    /// Codex provider identifier.
    public static let providerId = CodexProviderDefinition.providerId

    /// Configuration used to create a Codex provider adapter.
    public struct Configuration: Sendable {
        /// Codex executable path, or `/usr/bin/env` to resolve `codex` through `PATH`.
        public let executablePath: String
        /// Resolver used when `executablePath` is `/usr/bin/env`.
        public let executableResolver: any AgentProviderExecutableResolving
        /// Optional Codex home directory override, primarily for tests.
        public let codexHomeDirectory: URL?
        /// Additional environment values used for the App Server process.
        public let environment: [String: String]
        /// Whether App Server experimental APIs are enabled during initialization.
        public let experimentalAPIEnabled: Bool
        /// Maximum time to wait for App Server requests.
        public let requestTimeout: TimeInterval
        /// Maximum time to wait for App Server startup or probe requests.
        public let probeTimeout: TimeInterval
        /// Maximum time to wait for App Server shutdown.
        public let shutdownTimeout: TimeInterval
        /// Transport family used by this adapter.
        public let transportKind: CodexAppServerTransportKind
        /// Checker used for Codex feature support probes.
        public let featureSupportChecker: any CodexFeatureSupportChecking
        /// Store used to match host-owned durable session approvals.
        public let sessionApprovalPolicyStore: any AgentSessionApprovalPolicyStore
        /// Policy used to derive Bash command approval identity.
        public let commandApprovalNormalizationPolicy: AgentCommandApprovalNormalizationPolicy
        /// Factory used to create the transport lazily.
        public let makeTransport: @Sendable (Configuration) -> any CodexAppServerTransport

        /// Creates a Codex adapter configuration.
        /// - Parameters:
        ///   - executablePath: Codex executable path, or `/usr/bin/env` to resolve `codex` through `PATH`.
        ///   - codexHomeDirectory: Optional Codex home directory override, primarily for tests.
        ///   - environment: Additional environment values used for the App Server process.
        ///   - experimentalAPIEnabled: Whether App Server experimental APIs are enabled during initialization.
        ///   - requestTimeout: Maximum time to wait for App Server requests.
        ///   - probeTimeout: Maximum time to wait for App Server startup or probe requests.
        ///   - shutdownTimeout: Maximum time to wait for App Server shutdown.
        ///   - transportKind: Transport family used by this adapter.
        ///   - featureSupportChecker: Checker used for Codex feature support probes.
        ///   - sessionApprovalPolicyStore: Store used to match host-owned durable session approvals.
        ///   - commandApprovalNormalizationPolicy: Policy used to derive Bash command approval identity.
        ///   - makeTransport: Factory used to create the transport lazily.
        ///   - executableResolver: Resolver used when `executablePath` is `/usr/bin/env`.
        public init(
            executablePath: String = "/usr/bin/env",
            codexHomeDirectory: URL? = nil,
            environment: [String: String] = [:],
            experimentalAPIEnabled: Bool = true,
            requestTimeout: TimeInterval = 30,
            probeTimeout: TimeInterval = 10,
            shutdownTimeout: TimeInterval = 5,
            transportKind: CodexAppServerTransportKind = .stdio,
            featureSupportChecker: any CodexFeatureSupportChecking = DefaultCodexFeatureSupportChecker(),
            sessionApprovalPolicyStore: any AgentSessionApprovalPolicyStore = InMemoryAgentApprovalPolicyStore(),
            commandApprovalNormalizationPolicy: AgentCommandApprovalNormalizationPolicy = .default,
            makeTransport: (@Sendable (Configuration) -> any CodexAppServerTransport)? = nil,
            executableResolver: any AgentProviderExecutableResolving = DefaultAgentProviderExecutableResolver()
        ) {
            self.executablePath = executablePath
            self.executableResolver = executableResolver
            self.codexHomeDirectory = codexHomeDirectory
            self.environment = environment
            self.experimentalAPIEnabled = experimentalAPIEnabled
            self.requestTimeout = requestTimeout
            self.probeTimeout = probeTimeout
            self.shutdownTimeout = shutdownTimeout
            self.transportKind = transportKind
            self.featureSupportChecker = featureSupportChecker
            self.sessionApprovalPolicyStore = sessionApprovalPolicyStore
            self.commandApprovalNormalizationPolicy = commandApprovalNormalizationPolicy
            self.makeTransport = makeTransport ?? { CodexStdioAppServerTransport(configuration: $0) }
        }
    }

    /// Static Codex provider metadata.
    public let definition = CodexProviderDefinition.definition

    let configuration: Configuration
    private let client: CodexAppServerClient

    /// Creates a Codex provider adapter.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.client = CodexAppServerClient(configuration: configuration)
    }

    /// Bootstraps or resumes a Codex App Server thread and returns a lightweight runtime sentinel process.
    public func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        guard spawnConfig.hostTools.isEmpty else {
            throw AgentCLIError.hostToolsUnavailable(reason: "Context-aware launch is required for host tools.")
        }
        return try await makeLaunchConfiguration(
            spawnConfig: spawnConfig,
            resumedSession: resumedSession,
            hostToolEndpoint: nil,
            processToken: nil
        )
    }

    /// Bootstraps Codex with process-scoped host tools and workspace roots.
    public func makeLaunchConfiguration(context: AgentProviderLaunchContext) async throws -> AgentLaunchConfiguration {
        let endpoint = try context.validatedHostToolEndpoint()
        return try await makeLaunchConfiguration(
            spawnConfig: context.spawnConfig,
            resumedSession: context.resumedSession,
            hostToolEndpoint: endpoint,
            processToken: context.processToken
        )
    }

    private func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?,
        hostToolEndpoint: AgentHostToolEndpoint?,
        processToken: UUID?
    ) async throws -> AgentLaunchConfiguration {
        try spawnConfig.validateAdditionalWorkspaceRoots()
        let bootstrap: CodexThreadBootstrap
        do {
            bootstrap = try await client.bootstrapThread(
                spawnConfig: spawnConfig,
                resumedSession: resumedSession,
                hostToolEndpoint: hostToolEndpoint,
                processToken: processToken
            )
        } catch {
            if let processToken {
                await client.processDidTerminate(processToken: processToken)
            }
            throw error
        }
        return AgentLaunchConfiguration(
            executable: "/usr/bin/env",
            arguments: [
                "sh",
                "-c",
                "printf '%s\\n' \"$1\"; sleep 2147483647",
                "codex-bootstrap",
                try Self.bootstrapLine(
                    threadId: bootstrap.threadId,
                    name: bootstrap.name,
                    preview: bootstrap.preview,
                    forkedFromId: bootstrap.forkedFromId,
                    goal: bootstrap.goal
                )
            ],
            workingDirectory: spawnConfig.workingDirectory,
            sessionContinuity: bootstrap.continuity,
            providerSessionId: bootstrap.threadId,
            includesSpawnArguments: true
        )
    }

    /// Retires process-scoped App Server redaction values after the host route is invalidated.
    public func processDidTerminate(processToken: UUID) async {
        await client.processDidTerminate(processToken: processToken)
    }

    /// Decodes Codex bootstrap sentinel output.
    public func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] {
        guard let data = line.data(using: .utf8),
              let payload = try? JSONDecoder().decode(CodexBootstrapPayload.self, from: data),
              payload.codexAppServerBootstrap == true else {
            return [.rawOutput(AgentRawOutputEvent(text: line, isComplete: true))]
        }
        let threadId = AgentSessionID(rawValue: payload.threadId)
        var metadata: [String: JSONValue] = [
            "codex_thread_id": .string(payload.threadId),
            "provider_session_id": .string(payload.threadId),
            "codex_source": .string("bootstrap")
        ]
        if let forkedFromId = payload.forkedFromId {
            metadata["codex_forked_from_id"] = .string(forkedFromId)
        }
        var events: [AgentEvent] = [.sessionMetadata(AgentSessionMetadataEvent(
            providerSessionId: threadId,
            name: payload.name,
            preview: payload.preview,
            metadata: metadata
        ))]
        if let goal = payload.goal {
            events.append(.goal(AgentGoalEvent(snapshot: goal)))
        }
        return events
    }

    /// Extracts Codex's App Server thread identifier from session metadata and legacy bootstrap diagnostics.
    public func sessionID(from event: AgentEvent) -> AgentSessionID? {
        if case let .sessionMetadata(metadata) = event {
            return metadata.providerSessionId
        }
        guard case let .diagnostic(diagnostic) = event,
              case let .string(threadId)? = diagnostic.metadata["codex_thread_id"],
              !threadId.isEmpty else {
            return nil
        }
        return AgentSessionID(rawValue: threadId)
    }

    /// Encodes no process stdin bytes because Codex turns are sent through App Server requests.
    public func encodeInput(_ input: AgentInput) async throws -> Data {
        throw AgentCLIError.invalidInput("Codex App Server input requires runtime context.")
    }

    /// Sends Codex input through App Server `turn/start`, `turn/steer`, or related requests.
    public func encodeInput(_ input: AgentInput, context: AgentProviderInputContext) async throws -> Data {
        try await client.send(input, context: context)
        return Data()
    }

    /// Returns Codex App Server notification events for the bound runtime conversation.
    public func runtimeEvents(context: AgentProviderRuntimeContext) async -> AsyncStream<AgentProviderRuntimeEvent> {
        await client.runtimeEvents(context: context)
    }

    /// Interrupts the active Codex App Server turn.
    public func interrupt(context: AgentProviderInterruptContext) async throws {
        try await client.interrupt(context: context)
    }

    /// Applies idle-thread settings through Codex App Server without replacing the sentinel process.
    public func reconfigure(context: AgentProviderReconfigureContext) async throws -> AgentProviderReconfigureResult {
        try await client.reconfigure(context: context)
    }

    /// Performs native Codex goal actions through App Server goal APIs.
    public func performGoalAction(_ action: AgentGoalAction, context: AgentProviderGoalActionContext) async throws {
        try await client.performGoalAction(action, context: context)
    }

    /// Starts a native Codex goal through App Server goal APIs without starting a turn.
    public func startGoal(_ objective: String, context: AgentProviderGoalStartContext) async throws {
        try await client.startGoal(objective, context: context)
    }

    /// Archives a Codex App Server thread without starting or resuming a runtime session.
    public func archiveSession(_ record: AgentSessionRecord) async throws {
        try validateSessionActionRecord(record)
        try await client.archiveThread(record.providerSessionId)
    }

    /// Unarchives a Codex App Server thread without starting or resuming a runtime session.
    public func unarchiveSession(_ record: AgentSessionRecord) async throws {
        try validateSessionActionRecord(record)
        try await client.unarchiveThread(record.providerSessionId)
    }

    /// Deletes a Codex App Server thread without starting or resuming a runtime session.
    public func deleteSession(_ record: AgentSessionRecord) async throws {
        try validateSessionActionRecord(record)
        try await client.deleteThread(record.providerSessionId)
    }

    /// Stops the shared App Server transport.
    public func shutdownProviderResources() async {
        await client.shutdown()
    }

    private static func bootstrapLine(
        threadId: AgentSessionID,
        name: String?,
        preview: String?,
        forkedFromId: AgentSessionID?,
        goal: AgentGoalSnapshot?
    ) throws -> String {
        let payload = CodexBootstrapPayload(
            codexAppServerBootstrap: true,
            threadId: threadId.rawValue,
            name: name,
            preview: preview,
            forkedFromId: forkedFromId?.rawValue,
            goal: goal
        )
        let data = try JSONEncoder().encode(payload)
        guard let line = String(data: data, encoding: .utf8) else {
            throw AgentCLIError.invalidInput("Could not encode Codex bootstrap line.")
        }
        return line
    }
}

private struct CodexBootstrapPayload: Codable {
    let codexAppServerBootstrap: Bool
    let threadId: String
    let name: String?
    let preview: String?
    let forkedFromId: String?
    let goal: AgentGoalSnapshot?
}

extension CodexProviderAdapter.Configuration {
    func resolvingExecutableIfNeeded(for definition: AgentProviderDefinition) async -> Self {
        let resolvedConfiguration: Self
        if executablePath == "/usr/bin/env",
           let resolvedPath = await executableResolver.resolvedExecutablePath(for: definition) {
            resolvedConfiguration = replacingExecutablePath(resolvedPath)
        } else {
            resolvedConfiguration = self
        }
        return resolvedConfiguration.injectingCodeModeHostPathIfAvailable()
    }

    func resolvingExecutableIfNeeded(
        for definition: AgentProviderDefinition,
        availability: AgentProviderAvailability?
    ) async -> Self {
        guard executablePath == "/usr/bin/env" else {
            return injectingCodeModeHostPathIfAvailable()
        }
        if let executablePath = availability?.executablePath, !executablePath.isEmpty {
            return replacingExecutablePath(executablePath)
                .injectingCodeModeHostPathIfAvailable()
        }
        return await resolvingExecutableIfNeeded(for: definition)
    }

    private func injectingCodeModeHostPathIfAvailable() -> Self {
        let environmentKey = "CODEX_CODE_MODE_HOST_PATH"
        guard environment[environmentKey] == nil,
              executablePath != "/usr/bin/env" else {
            return self
        }
        let canonicalExecutable = AgentPathHelpers.canonicalFileURL(URL(fileURLWithPath: executablePath))
        let codeModeHost = canonicalExecutable
            .deletingLastPathComponent()
            .appendingPathComponent("codex-code-mode-host", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: codeModeHost.path) else {
            return self
        }
        var resolvedEnvironment = environment
        // Codex resolves this companion relative to its invocation path, which can be a symlink outside the install directory.
        resolvedEnvironment[environmentKey] = codeModeHost.path
        return replacingExecutablePath(executablePath, environment: resolvedEnvironment)
    }

    private func replacingExecutablePath(
        _ executablePath: String,
        environment: [String: String]? = nil
    ) -> Self {
        Self(
            executablePath: executablePath,
            codexHomeDirectory: codexHomeDirectory,
            environment: environment ?? self.environment,
            experimentalAPIEnabled: experimentalAPIEnabled,
            requestTimeout: requestTimeout,
            probeTimeout: probeTimeout,
            shutdownTimeout: shutdownTimeout,
            transportKind: transportKind,
            featureSupportChecker: featureSupportChecker,
            sessionApprovalPolicyStore: sessionApprovalPolicyStore,
            commandApprovalNormalizationPolicy: commandApprovalNormalizationPolicy,
            makeTransport: makeTransport,
            executableResolver: executableResolver
        )
    }
}

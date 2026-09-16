import Foundation

/// Embeds the stable OpenCode server API while the generic runtime owns host conversation state.
public struct OpenCodeHarnessAdapter: AgentHarnessAdapter {
    public static let harnessId = OpenCodeHarnessDefinition.harnessId
    public let definition = OpenCodeHarnessDefinition.definition

    /// Factories and timeouts also allow deterministic recovery tests without launching a CLI.
    public struct Configuration: Sendable {
        public let executablePath: String
        public let executableResolver: any AgentHarnessExecutableResolving
        public let environment: [String: String]
        public let startupTimeout: TimeInterval
        public let requestTimeout: TimeInterval
        public let shutdownTimeout: TimeInterval
        public let sessionApprovalPolicyStore: any AgentSessionApprovalPolicyStore
        public let commandApprovalNormalizationPolicy: AgentCommandApprovalNormalizationPolicy
        public let makeTransport: @Sendable (OpenCodeServerConfiguration) -> any OpenCodeServerTransport
        /// Runs bounded, isolated version and model checks before a one-shot command is exposed to its caller.
        public let oneShotShellRunner: any ShellRunning

        public init(
            executablePath: String = "/usr/bin/env",
            environment: [String: String] = [:],
            startupTimeout: TimeInterval = 10,
            requestTimeout: TimeInterval = 30,
            shutdownTimeout: TimeInterval = 3,
            executableResolver: any AgentHarnessExecutableResolving = DefaultAgentHarnessExecutableResolver(),
            sessionApprovalPolicyStore: any AgentSessionApprovalPolicyStore = InMemoryAgentApprovalPolicyStore(),
            commandApprovalNormalizationPolicy: AgentCommandApprovalNormalizationPolicy = .default,
            oneShotShellRunner: any ShellRunning = ProcessShellRunner(),
            makeTransport: @escaping @Sendable (OpenCodeServerConfiguration) -> any OpenCodeServerTransport = {
                OpenCodeHTTPServerTransport(configuration: $0)
            }
        ) {
            self.executablePath = executablePath
            self.executableResolver = executableResolver
            self.environment = environment
            self.startupTimeout = startupTimeout
            self.requestTimeout = requestTimeout
            self.shutdownTimeout = shutdownTimeout
            self.sessionApprovalPolicyStore = sessionApprovalPolicyStore
            self.commandApprovalNormalizationPolicy = commandApprovalNormalizationPolicy
            self.makeTransport = makeTransport
            self.oneShotShellRunner = oneShotShellRunner
        }
    }

    private let client: OpenCodeClient
    let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        client = OpenCodeClient(configuration: configuration)
    }

    public func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig, resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration {
        try await makeLaunchConfiguration(context: AgentHarnessLaunchContext(
            conversationId: resumedSession?.conversationId ?? AgentConversationID(rawValue: UUID().uuidString),
            processToken: UUID(), spawnConfig: spawnConfig, resumedSession: resumedSession
        ))
    }

    public func makeLaunchConfiguration(context: AgentHarnessLaunchContext) async throws -> AgentLaunchConfiguration {
        let endpoint = try context.validatedHostToolEndpoint()
        let bootstrap = try await client.bootstrap(context, endpoint: endpoint)
        // Runtime lifetime remains represented by a process, as with the App Server adapter.
        return AgentLaunchConfiguration(
            executable: "/bin/sleep", arguments: ["2147483647"],
            workingDirectory: context.spawnConfig.workingDirectory,
            sessionContinuity: bootstrap.continuity,
            harnessSessionId: AgentSessionID(rawValue: bootstrap.sessionID),
            includesSpawnArguments: true, sendsInitialPromptOverStdin: true
        )
    }

    public func decodeStdoutLine(_ line: String) async throws -> [AgentEvent] { [] }

    public func sessionID(from event: AgentEvent) -> AgentSessionID? {
        guard case let .sessionMetadata(value) = event else { return nil }
        return value.harnessSessionId
    }

    public func encodeInput(_ input: AgentInput) async throws -> Data {
        throw AgentCLIError.invalidInput("OpenCode input requires an active runtime context.")
    }

    public func encodeInput(_ input: AgentInput, context: AgentHarnessInputContext) async throws -> Data {
        try await client.send(input, context: context)
        return Data()
    }

    public func runtimeEvents(context: AgentHarnessRuntimeContext) async -> AsyncStream<AgentHarnessRuntimeEvent> {
        await client.events(processToken: context.processToken)
    }

    public func interrupt(context: AgentHarnessInterruptContext) async throws {
        try await client.interrupt(processToken: context.processToken)
    }

    public func reconfigure(context: AgentHarnessReconfigureContext) async throws -> AgentHarnessReconfigureResult {
        try OpenCodeClient.validate(context.newConfig)
        return context.isTurnActive ? .nextTurnRequired : .restartRequired
    }

    public func archiveSession(_ record: AgentSessionRecord) async throws {
        for id in record.supersededHarnessSessionIds + [record.harnessSessionId] {
            try await client.sessionAction("archive", record: record.retargeted(to: id))
        }
    }

    public func unarchiveSession(_ record: AgentSessionRecord) async throws {
        throw AgentCLIError.unsupportedCapability(harnessId: .opencode, capability: "native session unarchiving")
    }

    public func deleteSession(_ record: AgentSessionRecord) async throws {
        for id in record.supersededHarnessSessionIds {
            try await client.sessionAction("archive", record: record.retargeted(to: id))
        }
        try await client.sessionAction("delete", record: record)
    }

    public func processDidTerminate(processToken: UUID) async { await client.stop(processToken: processToken) }
    public func shutdownHarnessResources() async { await client.shutdown() }
}

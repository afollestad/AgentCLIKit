import Foundation

/// Provider adapter used by the generic runtime to launch, decode, and encode a CLI.
public protocol AgentProviderAdapter: Sendable {
    /// Static metadata for this provider.
    var definition: AgentProviderDefinition { get }

    /// Builds the launch configuration for a session.
    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration

    /// Builds a launch configuration with runtime-owned process context.
    func makeLaunchConfiguration(context: AgentProviderLaunchContext) async throws -> AgentLaunchConfiguration

    /// Builds a CLI command for a sessionless one-shot prompt.
    func makeOneShotPromptCommand(request: AgentOneShotPromptRequest) async throws -> ShellCommand

    /// Extracts final assistant text from a completed sessionless one-shot command.
    func finalOneShotPromptText(
        stdout: String,
        stderr: String,
        request: AgentOneShotPromptRequest
    ) async throws -> String

    /// Gives the provider a chance to augment a launch before the runtime starts the process.
    /// - Parameters:
    ///   - launch: Base launch configuration returned by `makeLaunchConfiguration(context:)`.
    ///   - spawnConfig: Host spawn configuration for the conversation.
    ///   - conversationId: Runtime conversation identifier for the launch.
    ///   - processToken: Runtime-scoped token that identifies this specific process generation.
    func prepareLaunchConfiguration(
        _ launch: AgentLaunchConfiguration,
        spawnConfig: AgentSpawnConfig,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async throws -> AgentLaunchConfiguration

    /// Decodes one complete stdout line into provider-neutral events.
    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent]

    /// Decodes one complete stdout line with runtime context into provider-neutral events.
    func decodeStdoutLine(_ line: String, context: AgentProviderOutputContext) async throws -> [AgentEvent]

    /// Extracts a provider session identifier from a decoded event when the provider reports one.
    func sessionID(from event: AgentEvent) -> AgentSessionID?

    /// Encodes host input into provider stdin data.
    func encodeInput(_ input: AgentInput) async throws -> Data

    /// Encodes host input with runtime context into provider stdin data.
    func encodeInput(_ input: AgentInput, context: AgentProviderInputContext) async throws -> Data

    /// Creates a runtime event after a marked steering input has been accepted by the provider input path.
    func acceptedSteeringInputEvent(for message: AgentMessageInput, context: AgentProviderInputContext) -> AgentEvent?

    /// Subscribes to provider-owned runtime events that do not arrive through stdout or stderr.
    func runtimeEvents(context: AgentProviderRuntimeContext) async -> AsyncStream<AgentProviderRuntimeEvent>

    /// Sends a provider-native interruption request for the active turn, if supported.
    func interrupt(context: AgentProviderInterruptContext) async throws

    /// Starts a provider-native goal in an already-running session, if supported.
    func startGoal(_ objective: String, context: AgentProviderGoalStartContext) async throws

    /// Encodes provider-native stdin bytes for starting a goal in an already-running session.
    func encodeGoalStart(_ objective: String, context: AgentProviderGoalStartContext) async throws -> AgentProviderEncodedGoalStart?

    /// Returns currently actionable goal controls after provider-specific runtime restrictions are applied.
    func availableGoalActions(for goal: AgentGoalSnapshot, context: AgentProviderGoalActionContext) -> [AgentGoalAction]

    /// Performs a provider-native goal action, if supported.
    func performGoalAction(_ action: AgentGoalAction, context: AgentProviderGoalActionContext) async throws

    /// Encodes provider-native stdin bytes for a goal action when the provider controls goals through stdin.
    func encodeGoalAction(_ action: AgentGoalAction, context: AgentProviderGoalActionContext) async throws -> Data?

    /// Gives the provider a chance to apply a new spawn configuration without replacing the process.
    func reconfigure(context: AgentProviderReconfigureContext) async throws -> AgentProviderReconfigureResult

    /// Archives a provider-native session when the provider supports it.
    func archiveSession(_ record: AgentSessionRecord) async throws

    /// Unarchives a provider-native session when the provider supports it.
    func unarchiveSession(_ record: AgentSessionRecord) async throws

    /// Deletes a provider-native session when the provider supports it.
    func deleteSession(_ record: AgentSessionRecord) async throws

    /// Notifies the provider that runtime-observed permission mode changed for a conversation.
    func permissionModeDidChange(_ mode: String?, conversationId: AgentConversationID) async

    /// Notifies the provider that a process generation has ended or been superseded.
    /// Cleanup must be idempotent because cancelled launches can receive an early invalidation and a final post-cancellation invalidation.
    func processDidTerminate(processToken: UUID) async

    /// Permanently shuts down provider-owned resources retained across process launches.
    /// Implementations must be idempotent and prevent suspended or future launches from recreating shared resources after this returns.
    func shutdownProviderResources() async
}

/// Default behavior for optional provider adapter capabilities.
public extension AgentProviderAdapter {
    /// Bridges context-aware launches to the legacy launch requirement for source compatibility.
    func makeLaunchConfiguration(context: AgentProviderLaunchContext) async throws -> AgentLaunchConfiguration {
        guard context.hostToolEndpoint == nil,
              context.spawnConfig.hostTools.isEmpty,
              context.spawnConfig.additionalWorkspaceRoots.isEmpty else {
            throw AgentCLIError.unsupportedCapability(
                providerId: definition.id,
                capability: "host tools or additional workspace roots"
            )
        }
        return try await makeLaunchConfiguration(
            spawnConfig: context.spawnConfig,
            resumedSession: context.resumedSession
        )
    }

    /// Throws by default for providers that do not support sessionless one-shot prompts.
    func makeOneShotPromptCommand(request: AgentOneShotPromptRequest) async throws -> ShellCommand {
        throw AgentOneShotPromptError.unsupportedProvider(definition.id)
    }

    /// Throws by default for providers that do not support sessionless one-shot prompts.
    func finalOneShotPromptText(
        stdout: String,
        stderr: String,
        request: AgentOneShotPromptRequest
    ) async throws -> String {
        throw AgentOneShotPromptError.unsupportedProvider(definition.id)
    }

    /// Returns the launch unchanged for providers that do not need runtime-managed launch augmentation.
    func prepareLaunchConfiguration(
        _ launch: AgentLaunchConfiguration,
        spawnConfig: AgentSpawnConfig,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async throws -> AgentLaunchConfiguration {
        launch
    }

    /// Returns no session identifier for providers that do not expose resumable sessions in events.
    func sessionID(from event: AgentEvent) -> AgentSessionID? {
        nil
    }

    /// Decodes stdout using the legacy provider stdout decoder.
    func decodeStdoutLine(_ line: String, context: AgentProviderOutputContext) async throws -> [AgentEvent] {
        try await decodeStdoutLine(line)
    }

    /// Encodes input using the legacy provider stdin encoder.
    func encodeInput(_ input: AgentInput, context: AgentProviderInputContext) async throws -> Data {
        try await encodeInput(input)
    }

    /// Returns no runtime marker for providers that require provider-native steering proof.
    func acceptedSteeringInputEvent(for message: AgentMessageInput, context: AgentProviderInputContext) -> AgentEvent? {
        nil
    }

    /// Returns an immediately finished stream for providers that only emit process stdout or stderr.
    func runtimeEvents(context: AgentProviderRuntimeContext) async -> AsyncStream<AgentProviderRuntimeEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    /// Performs no provider-native interruption for process-only providers.
    func interrupt(context: AgentProviderInterruptContext) async throws {}

    /// Throws for providers that do not support existing-session goal start.
    func startGoal(_ objective: String, context: AgentProviderGoalStartContext) async throws {
        throw AgentCLIError.unsupportedCapability(providerId: definition.id, capability: "existing-session goal start")
    }

    /// Returns no stdin bytes for providers that do not start existing-session goals through stdin.
    func encodeGoalStart(_ objective: String, context: AgentProviderGoalStartContext) async throws -> AgentProviderEncodedGoalStart? {
        nil
    }

    /// Returns provider-reported actions by default.
    func availableGoalActions(for goal: AgentGoalSnapshot, context: AgentProviderGoalActionContext) -> [AgentGoalAction] {
        goal.availableActions
    }

    /// Throws for providers that do not support provider-native goal actions.
    func performGoalAction(_ action: AgentGoalAction, context: AgentProviderGoalActionContext) async throws {
        throw AgentCLIError.unsupportedCapability(providerId: definition.id, capability: "goal \(action.rawValue)")
    }

    /// Returns no stdin bytes for providers that do not control goals through stdin.
    func encodeGoalAction(_ action: AgentGoalAction, context: AgentProviderGoalActionContext) async throws -> Data? {
        nil
    }

    /// Requests the runtime's replacement-process reconfigure path for providers without in-place settings updates.
    func reconfigure(context: AgentProviderReconfigureContext) async throws -> AgentProviderReconfigureResult {
        .restartRequired
    }

    /// Validates the provider record and otherwise no-ops for providers without native archiving.
    func archiveSession(_ record: AgentSessionRecord) async throws {
        try validateSessionActionRecord(record)
    }

    /// Validates the provider record and otherwise no-ops for providers without native unarchiving.
    func unarchiveSession(_ record: AgentSessionRecord) async throws {
        try validateSessionActionRecord(record)
    }

    /// Validates the provider record and otherwise no-ops for providers without native deletion.
    func deleteSession(_ record: AgentSessionRecord) async throws {
        try validateSessionActionRecord(record)
    }

    /// Does nothing for providers without permission-mode-sensitive runtime resources.
    func permissionModeDidChange(_ mode: String?, conversationId: AgentConversationID) async {}

    /// Does nothing for providers that do not retain process-scoped resources.
    func processDidTerminate(processToken: UUID) async {}

    /// Does nothing for providers that do not retain shared runtime resources.
    func shutdownProviderResources() async {}

    /// Validates that a provider session record belongs to this provider adapter.
    func validateSessionActionRecord(_ record: AgentSessionRecord) throws {
        guard record.providerId == definition.id else {
            throw AgentCLIError.invalidInput(
                "Provider session record for '\(record.providerId.rawValue)' cannot be handled by '\(definition.id.rawValue)'."
            )
        }
    }
}

/// Provider-encoded input for starting a goal in an already-running session.
public struct AgentProviderEncodedGoalStart: Sendable {
    /// Provider stdin bytes.
    public let data: Data
    /// Whether the input starts provider work and should make the runtime mark a turn active.
    public let marksTurnActive: Bool

    /// Creates encoded goal-start input.
    public init(data: Data, marksTurnActive: Bool) {
        self.data = data
        self.marksTurnActive = marksTurnActive
    }
}

/// Runtime context supplied for provider-native existing-session goal start.
public struct AgentProviderGoalStartContext: Sendable {
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Runtime process generation token.
    public let processToken: UUID
    /// Provider session identifier known to the runtime.
    public let providerSessionId: AgentSessionID?
    /// Spawn configuration for the active process generation.
    public let spawnConfig: AgentSpawnConfig
    /// Whether the runtime currently considers a provider turn active.
    public let isTurnActive: Bool
    /// Whether host input can currently be sent to the provider.
    public let inputAvailability: AgentInputAvailability

    /// Creates provider goal-start context.
    public init(
        conversationId: AgentConversationID,
        processToken: UUID,
        providerSessionId: AgentSessionID?,
        spawnConfig: AgentSpawnConfig,
        isTurnActive: Bool,
        inputAvailability: AgentInputAvailability
    ) {
        self.conversationId = conversationId
        self.processToken = processToken
        self.providerSessionId = providerSessionId
        self.spawnConfig = spawnConfig
        self.isTurnActive = isTurnActive
        self.inputAvailability = inputAvailability
    }
}

/// Runtime context supplied for provider-native goal actions.
public struct AgentProviderGoalActionContext: Sendable {
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Runtime process generation token.
    public let processToken: UUID
    /// Provider session identifier known to the runtime.
    public let providerSessionId: AgentSessionID?
    /// Spawn configuration for the active process generation.
    public let spawnConfig: AgentSpawnConfig
    /// Latest provider-reported goal snapshot.
    public let goal: AgentGoalSnapshot?
    /// Whether the runtime currently considers a provider turn active.
    public let isTurnActive: Bool
    /// Whether host input can currently be sent to the provider.
    public let inputAvailability: AgentInputAvailability

    /// Creates provider goal action context.
    public init(
        conversationId: AgentConversationID,
        processToken: UUID,
        providerSessionId: AgentSessionID?,
        spawnConfig: AgentSpawnConfig,
        goal: AgentGoalSnapshot?,
        isTurnActive: Bool = false,
        inputAvailability: AgentInputAvailability = .available
    ) {
        self.conversationId = conversationId
        self.processToken = processToken
        self.providerSessionId = providerSessionId
        self.spawnConfig = spawnConfig
        self.goal = goal
        self.isTurnActive = isTurnActive
        self.inputAvailability = inputAvailability
    }
}

/// Runtime context supplied while a provider decodes process stdout.
public struct AgentProviderOutputContext: Sendable {
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Runtime process generation token.
    public let processToken: UUID
    /// Provider session identifier known to the runtime.
    public let providerSessionId: AgentSessionID?
    /// Spawn configuration for the active process generation.
    public let spawnConfig: AgentSpawnConfig

    /// Creates provider output context.
    public init(
        conversationId: AgentConversationID,
        processToken: UUID,
        providerSessionId: AgentSessionID?,
        spawnConfig: AgentSpawnConfig
    ) {
        self.conversationId = conversationId
        self.processToken = processToken
        self.providerSessionId = providerSessionId
        self.spawnConfig = spawnConfig
    }
}

/// Runtime context supplied while a provider encodes host input.
public struct AgentProviderInputContext: Sendable {
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Runtime process generation token.
    public let processToken: UUID
    /// Provider session identifier known to the runtime.
    public let providerSessionId: AgentSessionID?
    /// Spawn configuration for the active process generation.
    public let spawnConfig: AgentSpawnConfig
    /// Whether the runtime currently considers a provider turn active.
    public let isTurnActive: Bool

    /// Creates provider input context.
    public init(
        conversationId: AgentConversationID,
        processToken: UUID,
        providerSessionId: AgentSessionID?,
        spawnConfig: AgentSpawnConfig,
        isTurnActive: Bool
    ) {
        self.conversationId = conversationId
        self.processToken = processToken
        self.providerSessionId = providerSessionId
        self.spawnConfig = spawnConfig
        self.isTurnActive = isTurnActive
    }
}

/// Runtime context used to attach provider-owned event streams.
public struct AgentProviderRuntimeContext: Sendable {
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Runtime process generation token.
    public let processToken: UUID
    /// Provider session identifier known to the runtime.
    public let providerSessionId: AgentSessionID?
    /// Spawn configuration for the active process generation.
    public let spawnConfig: AgentSpawnConfig

    /// Creates provider runtime event context.
    public init(
        conversationId: AgentConversationID,
        processToken: UUID,
        providerSessionId: AgentSessionID?,
        spawnConfig: AgentSpawnConfig
    ) {
        self.conversationId = conversationId
        self.processToken = processToken
        self.providerSessionId = providerSessionId
        self.spawnConfig = spawnConfig
    }
}

/// Runtime context supplied for provider-native turn interruption.
public struct AgentProviderInterruptContext: Sendable {
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Runtime process generation token.
    public let processToken: UUID
    /// Provider session identifier known to the runtime.
    public let providerSessionId: AgentSessionID?
    /// Spawn configuration for the active process generation.
    public let spawnConfig: AgentSpawnConfig
    /// Optional host-supplied cancellation reason.
    public let reason: String?

    /// Creates provider interruption context.
    public init(
        conversationId: AgentConversationID,
        processToken: UUID,
        providerSessionId: AgentSessionID?,
        spawnConfig: AgentSpawnConfig,
        reason: String? = nil
    ) {
        self.conversationId = conversationId
        self.processToken = processToken
        self.providerSessionId = providerSessionId
        self.spawnConfig = spawnConfig
        self.reason = reason
    }
}

/// Runtime context supplied for provider-native reconfiguration.
public struct AgentProviderReconfigureContext: Sendable {
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Runtime process generation token.
    public let processToken: UUID
    /// Provider session identifier known to the runtime.
    public let providerSessionId: AgentSessionID?
    /// Spawn configuration currently active in the runtime.
    public let currentConfig: AgentSpawnConfig
    /// Desired spawn configuration requested by the host.
    public let newConfig: AgentSpawnConfig
    /// Whether the runtime currently considers a provider turn active.
    public let isTurnActive: Bool

    /// Creates provider reconfiguration context.
    public init(
        conversationId: AgentConversationID,
        processToken: UUID,
        providerSessionId: AgentSessionID?,
        currentConfig: AgentSpawnConfig,
        newConfig: AgentSpawnConfig,
        isTurnActive: Bool
    ) {
        self.conversationId = conversationId
        self.processToken = processToken
        self.providerSessionId = providerSessionId
        self.currentConfig = currentConfig
        self.newConfig = newConfig
        self.isTurnActive = isTurnActive
    }
}

/// Provider-specific outcome for a reconfiguration request.
public enum AgentProviderReconfigureResult: Equatable, Sendable {
    /// Let the generic runtime restart or resume the provider process.
    case restartRequired
    /// The provider applied the new configuration without process replacement.
    case appliedInPlace
    /// The provider has an active turn, so the host should retry with the new config before the next turn.
    case nextTurnRequired
}

/// Event emitted by provider-owned runtime resources outside process stdout and stderr.
public struct AgentProviderRuntimeEvent: Sendable {
    /// Provider-neutral event payload.
    public let event: AgentEvent
    /// Event source to store in the runtime envelope.
    public let source: AgentEventSource

    /// Creates a provider runtime event.
    public init(event: AgentEvent, source: AgentEventSource = .runtime) {
        self.event = event
        self.source = source
    }
}

/// Process launch configuration produced by a provider adapter.
public struct AgentLaunchConfiguration: Codable, Equatable, Sendable {
    /// Executable path to run.
    public let executable: String
    /// Command-line arguments.
    public let arguments: [String]
    /// Environment overrides.
    public let environment: [String: String]
    /// Working directory for the process.
    public let workingDirectory: URL?
    /// Provider session continuity outcome for this launch when known.
    public let sessionContinuity: AgentSessionContinuity?
    /// Provider session identifier known before process output is decoded, if available.
    public let providerSessionId: AgentSessionID?
    /// Whether `arguments` already include `AgentSpawnConfig.arguments`.
    public let includesSpawnArguments: Bool
    /// Whether the runtime should write `AgentSpawnConfig.initialPrompt` as the first provider stdin message.
    public let sendsInitialPromptOverStdin: Bool

    /// Creates a launch configuration.
    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        sessionContinuity: AgentSessionContinuity? = nil,
        providerSessionId: AgentSessionID? = nil,
        includesSpawnArguments: Bool = false,
        sendsInitialPromptOverStdin: Bool = false
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.sessionContinuity = sessionContinuity
        self.providerSessionId = providerSessionId
        self.includesSpawnArguments = includesSpawnArguments
        self.sendsInitialPromptOverStdin = sendsInitialPromptOverStdin
    }

    /// Decodes launch configuration, defaulting newer optional fields for older persisted values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.executable = try container.decode(String.self, forKey: .executable)
        self.arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        self.environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        self.workingDirectory = try container.decodeIfPresent(URL.self, forKey: .workingDirectory)
        self.sessionContinuity = try container.decodeIfPresent(AgentSessionContinuity.self, forKey: .sessionContinuity)
        self.providerSessionId = try container.decodeIfPresent(AgentSessionID.self, forKey: .providerSessionId)
        self.includesSpawnArguments = try container.decodeIfPresent(Bool.self, forKey: .includesSpawnArguments) ?? false
        self.sendsInitialPromptOverStdin = try container.decodeIfPresent(Bool.self, forKey: .sendsInitialPromptOverStdin) ?? false
    }
}

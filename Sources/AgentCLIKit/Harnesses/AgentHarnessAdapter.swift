import Foundation

/// Harness adapter used by the generic runtime to launch, decode, and encode a CLI.
public protocol AgentHarnessAdapter: Sendable {
    /// Static metadata for this harness.
    var definition: AgentHarnessDefinition { get }

    /// Builds the launch configuration for a session.
    func makeLaunchConfiguration(
        spawnConfig: AgentSpawnConfig,
        resumedSession: AgentSessionRecord?
    ) async throws -> AgentLaunchConfiguration

    /// Builds a launch configuration with runtime-owned process context.
    func makeLaunchConfiguration(context: AgentHarnessLaunchContext) async throws -> AgentLaunchConfiguration

    /// Builds a CLI command for a sessionless one-shot prompt.
    func makeOneShotPromptCommand(request: AgentOneShotPromptRequest) async throws -> ShellCommand

    /// Extracts final assistant text from a completed sessionless one-shot command.
    func finalOneShotPromptText(
        stdout: String,
        stderr: String,
        request: AgentOneShotPromptRequest
    ) async throws -> String

    /// Gives the harness a chance to augment a launch before the runtime starts the process.
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

    /// Decodes one complete stdout line into harness-neutral events.
    func decodeStdoutLine(_ line: String) async throws -> [AgentEvent]

    /// Decodes one complete stdout line with runtime context into harness-neutral events.
    func decodeStdoutLine(_ line: String, context: AgentHarnessOutputContext) async throws -> [AgentEvent]

    /// Extracts a harness session identifier from a decoded event when the harness reports one.
    func sessionID(from event: AgentEvent) -> AgentSessionID?

    /// Encodes host input into harness stdin data.
    func encodeInput(_ input: AgentInput) async throws -> Data

    /// Encodes host input with runtime context into harness stdin data.
    func encodeInput(_ input: AgentInput, context: AgentHarnessInputContext) async throws -> Data

    /// Creates a runtime event after a marked steering input has been accepted by the harness input path.
    func acceptedSteeringInputEvent(for message: AgentMessageInput, context: AgentHarnessInputContext) -> AgentEvent?

    /// Subscribes to harness-owned runtime events that do not arrive through stdout or stderr.
    func runtimeEvents(context: AgentHarnessRuntimeContext) async -> AsyncStream<AgentHarnessRuntimeEvent>

    /// Sends a harness-native interruption request for the active turn, if supported.
    func interrupt(context: AgentHarnessInterruptContext) async throws

    /// Starts a harness-native goal in an already-running session, if supported.
    func startGoal(_ objective: String, context: AgentHarnessGoalStartContext) async throws

    /// Encodes harness-native stdin bytes for starting a goal in an already-running session.
    func encodeGoalStart(_ objective: String, context: AgentHarnessGoalStartContext) async throws -> AgentHarnessEncodedGoalStart?

    /// Returns currently actionable goal controls after harness-specific runtime restrictions are applied.
    func availableGoalActions(for goal: AgentGoalSnapshot, context: AgentHarnessGoalActionContext) -> [AgentGoalAction]

    /// Performs a harness-native goal action, if supported.
    func performGoalAction(_ action: AgentGoalAction, context: AgentHarnessGoalActionContext) async throws

    /// Encodes harness-native stdin bytes for a goal action when the harness controls goals through stdin.
    func encodeGoalAction(_ action: AgentGoalAction, context: AgentHarnessGoalActionContext) async throws -> Data?

    /// Gives the harness a chance to apply a new spawn configuration without replacing the process.
    func reconfigure(context: AgentHarnessReconfigureContext) async throws -> AgentHarnessReconfigureResult

    /// Archives a harness-native session when the harness supports it.
    func archiveSession(_ record: AgentSessionRecord) async throws

    /// Unarchives a harness-native session when the harness supports it.
    func unarchiveSession(_ record: AgentSessionRecord) async throws

    /// Deletes a harness-native session when the harness supports it.
    func deleteSession(_ record: AgentSessionRecord) async throws

    /// Notifies the harness that runtime-observed permission mode changed for a conversation.
    func permissionModeDidChange(_ mode: String?, conversationId: AgentConversationID) async

    /// Notifies the harness that a process generation has ended or been superseded.
    /// Cleanup must be idempotent because cancelled launches can receive an early invalidation and a final post-cancellation invalidation.
    func processDidTerminate(processToken: UUID) async

    /// Permanently shuts down harness-owned resources retained across process launches.
    /// Implementations must be idempotent and prevent suspended or future launches from recreating shared resources after this returns.
    func shutdownHarnessResources() async
}

/// Harness-encoded input for starting a goal in an already-running session.
public struct AgentHarnessEncodedGoalStart: Sendable {
    /// Harness stdin bytes.
    public let data: Data
    /// Whether the input starts harness work and should make the runtime mark a turn active.
    public let marksTurnActive: Bool

    /// Creates encoded goal-start input.
    public init(data: Data, marksTurnActive: Bool) {
        self.data = data
        self.marksTurnActive = marksTurnActive
    }
}

/// Runtime context supplied for harness-native existing-session goal start.
public struct AgentHarnessGoalStartContext: Sendable {
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Runtime process generation token.
    public let processToken: UUID
    /// Harness session identifier known to the runtime.
    public let harnessSessionId: AgentSessionID?
    /// Spawn configuration for the active process generation.
    public let spawnConfig: AgentSpawnConfig
    /// Whether the runtime currently considers a harness turn active.
    public let isTurnActive: Bool
    /// Whether host input can currently be sent to the harness.
    public let inputAvailability: AgentInputAvailability

    /// Creates harness goal-start context.
    public init(
        conversationId: AgentConversationID,
        processToken: UUID,
        harnessSessionId: AgentSessionID?,
        spawnConfig: AgentSpawnConfig,
        isTurnActive: Bool,
        inputAvailability: AgentInputAvailability
    ) {
        self.conversationId = conversationId
        self.processToken = processToken
        self.harnessSessionId = harnessSessionId
        self.spawnConfig = spawnConfig
        self.isTurnActive = isTurnActive
        self.inputAvailability = inputAvailability
    }
}

/// Runtime context supplied for harness-native goal actions.
public struct AgentHarnessGoalActionContext: Sendable {
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Runtime process generation token.
    public let processToken: UUID
    /// Harness session identifier known to the runtime.
    public let harnessSessionId: AgentSessionID?
    /// Spawn configuration for the active process generation.
    public let spawnConfig: AgentSpawnConfig
    /// Latest harness-reported goal snapshot.
    public let goal: AgentGoalSnapshot?
    /// Whether the runtime currently considers a harness turn active.
    public let isTurnActive: Bool
    /// Whether host input can currently be sent to the harness.
    public let inputAvailability: AgentInputAvailability

    /// Creates harness goal action context.
    public init(
        conversationId: AgentConversationID,
        processToken: UUID,
        harnessSessionId: AgentSessionID?,
        spawnConfig: AgentSpawnConfig,
        goal: AgentGoalSnapshot?,
        isTurnActive: Bool = false,
        inputAvailability: AgentInputAvailability = .available
    ) {
        self.conversationId = conversationId
        self.processToken = processToken
        self.harnessSessionId = harnessSessionId
        self.spawnConfig = spawnConfig
        self.goal = goal
        self.isTurnActive = isTurnActive
        self.inputAvailability = inputAvailability
    }
}

/// Runtime context supplied while a harness decodes process stdout.
public struct AgentHarnessOutputContext: Sendable {
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Runtime process generation token.
    public let processToken: UUID
    /// Harness session identifier known to the runtime.
    public let harnessSessionId: AgentSessionID?
    /// Spawn configuration for the active process generation.
    public let spawnConfig: AgentSpawnConfig

    /// Creates harness output context.
    public init(
        conversationId: AgentConversationID,
        processToken: UUID,
        harnessSessionId: AgentSessionID?,
        spawnConfig: AgentSpawnConfig
    ) {
        self.conversationId = conversationId
        self.processToken = processToken
        self.harnessSessionId = harnessSessionId
        self.spawnConfig = spawnConfig
    }
}

/// Runtime context supplied while a harness encodes host input.
public struct AgentHarnessInputContext: Sendable {
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Runtime process generation token.
    public let processToken: UUID
    /// Harness session identifier known to the runtime.
    public let harnessSessionId: AgentSessionID?
    /// Spawn configuration for the active process generation.
    public let spawnConfig: AgentSpawnConfig
    /// Whether the runtime currently considers a harness turn active.
    public let isTurnActive: Bool

    /// Creates harness input context.
    public init(
        conversationId: AgentConversationID,
        processToken: UUID,
        harnessSessionId: AgentSessionID?,
        spawnConfig: AgentSpawnConfig,
        isTurnActive: Bool
    ) {
        self.conversationId = conversationId
        self.processToken = processToken
        self.harnessSessionId = harnessSessionId
        self.spawnConfig = spawnConfig
        self.isTurnActive = isTurnActive
    }
}

/// Runtime context used to attach harness-owned event streams.
public struct AgentHarnessRuntimeContext: Sendable {
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Runtime process generation token.
    public let processToken: UUID
    /// Harness session identifier known to the runtime.
    public let harnessSessionId: AgentSessionID?
    /// Spawn configuration for the active process generation.
    public let spawnConfig: AgentSpawnConfig

    /// Creates harness runtime event context.
    public init(
        conversationId: AgentConversationID,
        processToken: UUID,
        harnessSessionId: AgentSessionID?,
        spawnConfig: AgentSpawnConfig
    ) {
        self.conversationId = conversationId
        self.processToken = processToken
        self.harnessSessionId = harnessSessionId
        self.spawnConfig = spawnConfig
    }
}

/// Runtime context supplied for harness-native turn interruption.
public struct AgentHarnessInterruptContext: Sendable {
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Runtime process generation token.
    public let processToken: UUID
    /// Harness session identifier known to the runtime.
    public let harnessSessionId: AgentSessionID?
    /// Spawn configuration for the active process generation.
    public let spawnConfig: AgentSpawnConfig
    /// Optional host-supplied cancellation reason.
    public let reason: String?

    /// Creates harness interruption context.
    public init(
        conversationId: AgentConversationID,
        processToken: UUID,
        harnessSessionId: AgentSessionID?,
        spawnConfig: AgentSpawnConfig,
        reason: String? = nil
    ) {
        self.conversationId = conversationId
        self.processToken = processToken
        self.harnessSessionId = harnessSessionId
        self.spawnConfig = spawnConfig
        self.reason = reason
    }
}

/// Runtime context supplied for harness-native reconfiguration.
public struct AgentHarnessReconfigureContext: Sendable {
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Runtime process generation token.
    public let processToken: UUID
    /// Harness session identifier known to the runtime.
    public let harnessSessionId: AgentSessionID?
    /// Spawn configuration currently active in the runtime.
    public let currentConfig: AgentSpawnConfig
    /// Desired spawn configuration requested by the host.
    public let newConfig: AgentSpawnConfig
    /// Whether the runtime currently considers a harness turn active.
    public let isTurnActive: Bool

    /// Creates harness reconfiguration context.
    public init(
        conversationId: AgentConversationID,
        processToken: UUID,
        harnessSessionId: AgentSessionID?,
        currentConfig: AgentSpawnConfig,
        newConfig: AgentSpawnConfig,
        isTurnActive: Bool
    ) {
        self.conversationId = conversationId
        self.processToken = processToken
        self.harnessSessionId = harnessSessionId
        self.currentConfig = currentConfig
        self.newConfig = newConfig
        self.isTurnActive = isTurnActive
    }
}

/// Harness-specific outcome for a reconfiguration request.
public enum AgentHarnessReconfigureResult: Equatable, Sendable {
    /// Let the generic runtime restart or resume the harness process.
    case restartRequired
    /// The harness applied the new configuration without process replacement.
    case appliedInPlace
    /// The harness has an active turn, so the host should retry with the new config before the next turn.
    case nextTurnRequired
}

/// Event emitted by harness-owned runtime resources outside process stdout and stderr.
public struct AgentHarnessRuntimeEvent: Sendable {
    /// Harness-neutral event payload.
    public let event: AgentEvent
    /// Event source to store in the runtime envelope.
    public let source: AgentEventSource

    /// Creates a harness runtime event.
    public init(event: AgentEvent, source: AgentEventSource = .runtime) {
        self.event = event
        self.source = source
    }
}

/// Process launch configuration produced by a harness adapter.
public struct AgentLaunchConfiguration: Codable, Equatable, Sendable {
    /// Executable path to run.
    public let executable: String
    /// Command-line arguments.
    public let arguments: [String]
    /// Environment overrides.
    public let environment: [String: String]
    /// Working directory for the process.
    public let workingDirectory: URL?
    /// Harness session continuity outcome for this launch when known.
    public let sessionContinuity: AgentSessionContinuity?
    /// Harness session identifier known before process output is decoded, if available.
    public let harnessSessionId: AgentSessionID?
    /// Whether `arguments` already include `AgentSpawnConfig.arguments`.
    public let includesSpawnArguments: Bool
    /// Whether the runtime should write `AgentSpawnConfig.initialPrompt` as the first harness stdin message.
    public let sendsInitialPromptOverStdin: Bool

    /// Creates a launch configuration.
    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        sessionContinuity: AgentSessionContinuity? = nil,
        harnessSessionId: AgentSessionID? = nil,
        includesSpawnArguments: Bool = false,
        sendsInitialPromptOverStdin: Bool = false
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.sessionContinuity = sessionContinuity
        self.harnessSessionId = harnessSessionId
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
        self.harnessSessionId = try container.decodeIfPresent(AgentSessionID.self, forKey: .harnessSessionId)
        self.includesSpawnArguments = try container.decodeIfPresent(Bool.self, forKey: .includesSpawnArguments) ?? false
        self.sendsInitialPromptOverStdin = try container.decodeIfPresent(Bool.self, forKey: .sendsInitialPromptOverStdin) ?? false
    }

    /// Retains the persisted field names used before the harness terminology update.
    private enum CodingKeys: String, CodingKey {
        case executable
        case arguments
        case environment
        case workingDirectory
        case sessionContinuity
        case harnessSessionId = "providerSessionId"
        case includesSpawnArguments
        case sendsInitialPromptOverStdin
    }
}

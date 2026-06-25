import Foundation

/// Configuration used when spawning an agent session.
public struct AgentSpawnConfig: Codable, Equatable, Sendable {
    /// Provider to launch.
    public let providerId: AgentProviderID
    /// Working directory for the provider process.
    public let workingDirectory: URL
    /// Additional provider arguments.
    public let arguments: [String]
    /// Environment overrides.
    public let environment: [String: String]
    /// Optional model name.
    public let model: String?
    /// Optional provider effort setting.
    public let effort: String?
    /// Optional provider reasoning summary mode.
    ///
    /// Providers may use this to request live, model-authored reasoning summaries. A `nil`
    /// value leaves provider behavior unchanged.
    public let reasoningSummaryMode: AgentReasoningSummaryMode?
    /// Optional provider approval policy.
    public let permissionMode: String?
    /// Optional provider-neutral collaboration mode override.
    ///
    /// Hosts use `.plan` to enter plan mode and `.default` to leave plan mode. A `nil`
    /// value means the host is not overriding the provider's collaboration mode.
    /// Active turns cannot be mutated in place; providers apply changes to the next turn.
    public let collaborationMode: AgentCollaborationMode?
    /// Optional provider speed mode override.
    ///
    /// A `nil` value leaves provider behavior unchanged. Hosts should inspect
    /// `AgentProviderCapabilities.supportsSpeedMode` before sending `.fast`.
    public let speedMode: AgentSpeedMode?
    /// Optional provider-neutral initial goal objective.
    ///
    /// The visible host message remains `initialPrompt`. Providers that support native goal mode use `initialGoal`
    /// to configure goal pursuit without sending a duplicate visible prompt.
    public let initialGoal: String?
    /// Optional provider-native fork request.
    public let sessionFork: AgentSessionForkRequest?
    /// Whether a resumed provider session should fork instead of continuing in-place.
    ///
    /// Deprecated compatibility flag for older hosts. New hosts should use `sessionFork`
    /// so providers can fork from a source session into a different target working directory.
    public let forkSession: Bool
    /// Optional initial prompt sent by the provider launch command.
    public let initialPrompt: String?
    /// Optional attachments sent with the initial prompt when the provider supports structured input.
    public let initialPromptAttachments: [AgentInputAttachment]
    /// Provider-neutral metadata sent with the initial prompt.
    public let initialPromptMetadata: [String: JSONValue]

    /// Creates a spawn configuration.
    public init(
        providerId: AgentProviderID,
        workingDirectory: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        model: String? = nil,
        effort: String? = nil,
        reasoningSummaryMode: AgentReasoningSummaryMode? = nil,
        permissionMode: String? = nil,
        collaborationMode: AgentCollaborationMode? = nil,
        speedMode: AgentSpeedMode? = nil,
        initialGoal: String? = nil,
        sessionFork: AgentSessionForkRequest? = nil,
        forkSession: Bool = false,
        initialPrompt: String? = nil,
        initialPromptAttachments: [AgentInputAttachment] = [],
        initialPromptMetadata: [String: JSONValue] = [:]
    ) {
        self.providerId = providerId
        self.workingDirectory = workingDirectory
        self.arguments = arguments
        self.environment = environment
        self.model = model
        self.effort = effort
        self.reasoningSummaryMode = reasoningSummaryMode
        self.permissionMode = permissionMode
        self.collaborationMode = collaborationMode
        self.speedMode = speedMode
        self.initialGoal = initialGoal
        self.sessionFork = sessionFork
        self.forkSession = forkSession || sessionFork != nil
        self.initialPrompt = initialPrompt
        self.initialPromptAttachments = initialPromptAttachments
        self.initialPromptMetadata = initialPromptMetadata
    }

    /// Decodes spawn configuration, defaulting additive fields for older persisted values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.providerId = try container.decode(AgentProviderID.self, forKey: .providerId)
        self.workingDirectory = try container.decode(URL.self, forKey: .workingDirectory)
        self.arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        self.environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.effort = try container.decodeIfPresent(String.self, forKey: .effort)
        self.reasoningSummaryMode = try container.decodeIfPresent(AgentReasoningSummaryMode.self, forKey: .reasoningSummaryMode)
        self.permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
        self.collaborationMode = try container.decodeIfPresent(AgentCollaborationMode.self, forKey: .collaborationMode)
        self.speedMode = try container.decodeIfPresent(AgentSpeedMode.self, forKey: .speedMode)
        self.initialGoal = try container.decodeIfPresent(String.self, forKey: .initialGoal)
        self.sessionFork = try container.decodeIfPresent(AgentSessionForkRequest.self, forKey: .sessionFork)
        self.forkSession = (try container.decodeIfPresent(Bool.self, forKey: .forkSession) ?? false) || sessionFork != nil
        self.initialPrompt = try container.decodeIfPresent(String.self, forKey: .initialPrompt)
        self.initialPromptAttachments = try container.decodeIfPresent([AgentInputAttachment].self, forKey: .initialPromptAttachments) ?? []
        self.initialPromptMetadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .initialPromptMetadata) ?? [:]
    }
}

/// Provider-native request to fork an existing provider session into a new host conversation.
public struct AgentSessionForkRequest: Codable, Equatable, Sendable {
    /// Provider-defined source session identifier to fork from.
    public let sourceSessionId: AgentSessionID
    /// Source session working directory, when the provider requires it to locate persisted artifacts.
    public let sourceWorkingDirectory: URL?
    /// Host-requested fork target kind.
    public let mode: AgentSessionForkMode

    /// Creates a provider-native fork request.
    public init(
        sourceSessionId: AgentSessionID,
        sourceWorkingDirectory: URL? = nil,
        mode: AgentSessionForkMode = .local
    ) {
        self.sourceSessionId = sourceSessionId
        self.sourceWorkingDirectory = sourceWorkingDirectory.map(AgentPathHelpers.canonicalFileURL)
        self.mode = mode
    }

    /// Decodes a fork request, defaulting additive fields for older persisted values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sourceSessionId = try container.decode(AgentSessionID.self, forKey: .sourceSessionId)
        self.sourceWorkingDirectory = try container.decodeIfPresent(URL.self, forKey: .sourceWorkingDirectory)
            .map(AgentPathHelpers.canonicalFileURL)
        self.mode = try container.decodeIfPresent(AgentSessionForkMode.self, forKey: .mode) ?? .local
    }
}

/// Host-requested target kind for a provider-native session fork.
public enum AgentSessionForkMode: String, Codable, Equatable, Sendable {
    /// Fork into a normal local host conversation.
    case local
    /// Fork into a host-managed Git worktree conversation.
    case worktree
}

/// Provider-neutral collaboration mode for an agent session.
public enum AgentCollaborationMode: String, Codable, Equatable, Sendable {
    /// Normal provider behavior.
    case `default`
    /// Planning mode, where supported by the provider.
    case plan
}

/// Provider-neutral speed mode for an agent session.
public enum AgentSpeedMode: String, Codable, Equatable, Sendable {
    /// Normal provider behavior.
    case standard
    /// Faster provider behavior, where supported by the provider.
    case fast
}

/// Provider-neutral reasoning summary mode for agent sessions.
public enum AgentReasoningSummaryMode: String, Codable, Equatable, Sendable {
    /// Let the provider decide the summary verbosity.
    case auto
    /// Ask the provider for concise reasoning summaries.
    case concise
    /// Ask the provider for detailed reasoning summaries.
    case detailed
    /// Disable provider reasoning summaries.
    case none
}

/// Runtime status for a host conversation.
public struct AgentRuntimeStatus: Codable, Equatable, Sendable {
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Provider identifier.
    public let providerId: AgentProviderID
    /// Runtime generation.
    public let generation: Int
    /// Latest lifecycle state.
    public let state: AgentLifecycleState
    /// Last emitted event index.
    public let lastEventIndex: Int
    /// Provider session identifier when known.
    public let providerSessionId: AgentSessionID?
    /// Provider-reported user-facing session name when known.
    public let providerSessionName: String?
    /// Provider-reported user-facing session preview when known.
    public let providerSessionPreview: String?
    /// Latest provider-reported permission mode when known.
    public let permissionMode: String?
    /// Latest provider-neutral collaboration mode when known.
    public let collaborationMode: AgentCollaborationMode?
    /// Latest provider-reported goal state when a goal is active or terminal.
    public let goal: AgentGoalSnapshot?
    /// Whether a host-started provider turn is still active, even if mid-turn input is available.
    public let isTurnActive: Bool
    /// Whether host input can currently be sent to the provider.
    public let inputAvailability: AgentInputAvailability
    /// Runtime wait state derived from lifecycle and pending interactions.
    public let waitingState: AgentRuntimeWaitingState
    /// Provider process identifier when a process has been started.
    public let processIdentifier: Int32?
    /// Whether the provider process is currently running.
    public let isProcessRunning: Bool
    /// Whether cancellation is meaningful for the current lifecycle state.
    public let canCancel: Bool

    /// Creates a runtime status snapshot.
    public init(
        conversationId: AgentConversationID,
        providerId: AgentProviderID,
        generation: Int,
        state: AgentLifecycleState,
        lastEventIndex: Int,
        providerSessionId: AgentSessionID?,
        providerSessionName: String? = nil,
        providerSessionPreview: String? = nil,
        permissionMode: String? = nil,
        collaborationMode: AgentCollaborationMode? = nil,
        goal: AgentGoalSnapshot? = nil,
        isTurnActive: Bool = false,
        inputAvailability: AgentInputAvailability = .available,
        waitingState: AgentRuntimeWaitingState = .idle,
        processIdentifier: Int32? = nil,
        isProcessRunning: Bool = false,
        canCancel: Bool = false
    ) {
        self.conversationId = conversationId
        self.providerId = providerId
        self.generation = generation
        self.state = state
        self.lastEventIndex = lastEventIndex
        self.providerSessionId = providerSessionId
        self.providerSessionName = providerSessionName
        self.providerSessionPreview = providerSessionPreview
        self.permissionMode = permissionMode
        self.collaborationMode = collaborationMode
        self.goal = goal
        self.isTurnActive = isTurnActive
        self.inputAvailability = inputAvailability
        self.waitingState = waitingState
        self.processIdentifier = processIdentifier
        self.isProcessRunning = isProcessRunning
        self.canCancel = canCancel
    }

    /// Decodes a status snapshot, defaulting additive fields for older persisted values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.conversationId = try container.decode(AgentConversationID.self, forKey: .conversationId)
        self.providerId = try container.decode(AgentProviderID.self, forKey: .providerId)
        self.generation = try container.decode(Int.self, forKey: .generation)
        self.state = try container.decode(AgentLifecycleState.self, forKey: .state)
        self.lastEventIndex = try container.decode(Int.self, forKey: .lastEventIndex)
        self.providerSessionId = try container.decodeIfPresent(AgentSessionID.self, forKey: .providerSessionId)
        self.providerSessionName = try container.decodeIfPresent(String.self, forKey: .providerSessionName)
        self.providerSessionPreview = try container.decodeIfPresent(String.self, forKey: .providerSessionPreview)
        self.permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
        self.collaborationMode = try container.decodeIfPresent(AgentCollaborationMode.self, forKey: .collaborationMode)
        self.goal = try container.decodeIfPresent(AgentGoalSnapshot.self, forKey: .goal)
        self.isTurnActive = try container.decodeIfPresent(Bool.self, forKey: .isTurnActive) ?? false
        self.inputAvailability = try container.decodeIfPresent(AgentInputAvailability.self, forKey: .inputAvailability) ?? .available
        self.waitingState = try container.decodeIfPresent(AgentRuntimeWaitingState.self, forKey: .waitingState) ?? .idle
        self.processIdentifier = try container.decodeIfPresent(Int32.self, forKey: .processIdentifier)
        self.isProcessRunning = try container.decodeIfPresent(Bool.self, forKey: .isProcessRunning) ?? false
        self.canCancel = try container.decodeIfPresent(Bool.self, forKey: .canCancel) ?? false
    }
}

/// Host input availability for a running conversation.
public enum AgentInputAvailability: Codable, Equatable, Sendable {
    /// Input can be sent immediately.
    case available
    /// Input is temporarily blocked by a pending interaction or lifecycle state.
    case blocked(reason: String)
}

/// Runtime state that explains why a conversation is waiting.
public enum AgentRuntimeWaitingState: String, Codable, Hashable, Sendable {
    /// Runtime is not waiting on host action.
    case idle
    /// Runtime is waiting for a tool approval.
    case approval
    /// Runtime is waiting for a prompt answer.
    case prompt
    /// Runtime is waiting for permission to leave plan mode.
    case planModeExit
}

/// Result of applying a runtime reconfiguration request.
public enum AgentRuntimeReconfigureResult: String, Codable, Equatable, Sendable {
    /// The provider process was restarted or resumed with the new configuration.
    case restarted
    /// The provider applied the new configuration without replacing the process.
    case appliedInPlace
    /// The provider has an active turn, so the host should stage the configuration for the next turn.
    case nextTurnRequired
}

/// Async event subscription returned by an agent runtime.
public struct AgentEventSubscription: Sendable {
    /// Runtime generation for this subscription.
    public let generation: Int
    /// Events emitted after the requested cursor, including replayed buffered events.
    ///
    /// The stream is not main-actor isolated. UI hosts should receive values from a task and explicitly hop to their UI
    /// actor before mutating app state.
    public let events: AsyncStream<AgentEventEnvelope>

    /// Creates an event subscription.
    public init(generation: Int, events: AsyncStream<AgentEventEnvelope>) {
        self.generation = generation
        self.events = events
    }
}

/// Runtime contract for process-backed agent sessions.
///
/// Runtime implementations are `Sendable` and actor-safe. Host applications own persistence, UI projection, and main-actor
/// handoff; AgentCLIKit emits provider-neutral events and status snapshots that can be replayed by generation and index.
public protocol AgentRuntime: Sendable {
    /// Spawns or replaces the provider process for a conversation.
    func spawn(conversationId: AgentConversationID, config: AgentSpawnConfig) async throws
    /// Subscribes to events after a previously persisted event index.
    func subscribe(conversationId: AgentConversationID, afterIndex: Int?) async -> AgentEventSubscription
    /// Subscribes to runtime status snapshots for a conversation.
    func statusUpdates(conversationId: AgentConversationID) async -> AsyncStream<AgentRuntimeStatus>
    /// Marks events as persisted by the host so replay buffers can be compacted.
    func markPersisted(conversationId: AgentConversationID, generation: Int, upTo index: Int) async
    /// Sends input to the provider process.
    func send(_ input: AgentInput, conversationId: AgentConversationID) async throws
    /// Resolves a pending interaction and forwards the resolution to providers that accept one over input.
    func resolveInteraction(_ resolution: AgentInteractionResolution, conversationId: AgentConversationID) async throws
    /// Starts a provider-native goal in an already-running session.
    func startGoal(_ objective: String, conversationId: AgentConversationID) async throws
    /// Performs a provider-native goal action.
    func performGoalAction(_ action: AgentGoalAction, conversationId: AgentConversationID) async throws
    /// Sends an interrupt request and terminates the provider process.
    func cancel(conversationId: AgentConversationID) async
    /// Immediately kills the provider process.
    func kill(conversationId: AgentConversationID) async
    /// Destroys runtime state for a conversation.
    func destroy(conversationId: AgentConversationID) async
    /// Shuts down runtime-owned shared resources such as local hook listeners.
    func shutdown() async
    /// Reconfigures a conversation.
    ///
    /// Providers may apply idle-thread settings in place. Active turns are not mutated; callers should
    /// treat `.nextTurnRequired` as a request to stage `config` for the next outbound turn.
    @discardableResult
    func reconfigure(conversationId: AgentConversationID, config: AgentSpawnConfig) async throws -> AgentRuntimeReconfigureResult
    /// Starts a fresh generation for the conversation.
    func freshSession(conversationId: AgentConversationID, config: AgentSpawnConfig) async throws
    /// Returns current runtime status for a conversation.
    func status(conversationId: AgentConversationID) async -> AgentRuntimeStatus?
}

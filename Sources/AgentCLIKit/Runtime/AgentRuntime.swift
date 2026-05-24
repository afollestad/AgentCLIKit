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
    /// Optional initial prompt sent by the provider launch command.
    public let initialPrompt: String?

    /// Creates a spawn configuration.
    public init(
        providerId: AgentProviderID,
        workingDirectory: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        model: String? = nil,
        effort: String? = nil,
        initialPrompt: String? = nil
    ) {
        self.providerId = providerId
        self.workingDirectory = workingDirectory
        self.arguments = arguments
        self.environment = environment
        self.model = model
        self.effort = effort
        self.initialPrompt = initialPrompt
    }
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
    /// Latest provider permission mode when known.
    public let permissionMode: String?
    /// Whether host input can currently be sent to the provider.
    public let inputAvailability: AgentInputAvailability
    /// Runtime wait state derived from lifecycle and pending interactions.
    public let waitingState: AgentRuntimeWaitingState

    /// Creates a runtime status snapshot.
    public init(
        conversationId: AgentConversationID,
        providerId: AgentProviderID,
        generation: Int,
        state: AgentLifecycleState,
        lastEventIndex: Int,
        providerSessionId: AgentSessionID?,
        permissionMode: String? = nil,
        inputAvailability: AgentInputAvailability = .available,
        waitingState: AgentRuntimeWaitingState = .idle
    ) {
        self.conversationId = conversationId
        self.providerId = providerId
        self.generation = generation
        self.state = state
        self.lastEventIndex = lastEventIndex
        self.providerSessionId = providerSessionId
        self.permissionMode = permissionMode
        self.inputAvailability = inputAvailability
        self.waitingState = waitingState
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
        self.permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
        self.inputAvailability = try container.decodeIfPresent(AgentInputAvailability.self, forKey: .inputAvailability) ?? .available
        self.waitingState = try container.decodeIfPresent(AgentRuntimeWaitingState.self, forKey: .waitingState) ?? .idle
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

/// Async event subscription returned by an agent runtime.
public struct AgentEventSubscription: Sendable {
    /// Runtime generation for this subscription.
    public let generation: Int
    /// Events emitted after the requested cursor, including replayed buffered events.
    public let events: AsyncStream<AgentEventEnvelope>

    /// Creates an event subscription.
    public init(generation: Int, events: AsyncStream<AgentEventEnvelope>) {
        self.generation = generation
        self.events = events
    }
}

/// Runtime contract for process-backed agent sessions.
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
    /// Sends an interrupt request and terminates the provider process.
    func cancel(conversationId: AgentConversationID) async
    /// Immediately kills the provider process.
    func kill(conversationId: AgentConversationID) async
    /// Destroys runtime state for a conversation.
    func destroy(conversationId: AgentConversationID) async
    /// Shuts down runtime-owned shared resources such as local hook listeners.
    func shutdown() async
    /// Reconfigures a conversation by spawning a replacement process.
    func reconfigure(conversationId: AgentConversationID, config: AgentSpawnConfig) async throws
    /// Starts a fresh generation for the conversation.
    func freshSession(conversationId: AgentConversationID, config: AgentSpawnConfig) async throws
    /// Returns current runtime status for a conversation.
    func status(conversationId: AgentConversationID) async -> AgentRuntimeStatus?
}

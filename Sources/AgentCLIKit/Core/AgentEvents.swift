import Foundation

/// Source channel that produced an agent event.
public enum AgentEventSource: String, Codable, Hashable, Sendable {
    /// Event decoded from harness stdout.
    case stdout
    /// Diagnostic data decoded or captured from harness stderr.
    case stderr
    /// Process lifecycle event emitted by the runtime.
    case process
    /// Harness hook event emitted through a local hook listener.
    case hook
    /// Internal runtime event emitted by AgentCLIKit.
    case runtime
    /// Host-provided event injected by the app.
    case host
}

/// Harness-neutral event envelope used for replay, persistence, and subscription cursors.
public struct AgentEventEnvelope: Codable, Equatable, Sendable {
    /// Runtime generation for the conversation. Fresh sessions increment this value.
    public let generation: Int
    /// Monotonic event index within a generation.
    public let index: Int
    /// Harness that produced or owns the event.
    public let harnessId: AgentHarnessID
    /// Host-defined app conversation identifier.
    public let conversationId: AgentConversationID
    /// Harness session identifier when known.
    public let harnessSessionId: AgentSessionID?
    /// Source channel for the enclosed event.
    public let source: AgentEventSource
    /// The harness-neutral event payload.
    public let event: AgentEvent
    /// Wall-clock time when the runtime created the envelope.
    public let createdAt: Date

    /// Creates an event envelope.
    public init(
        generation: Int,
        index: Int,
        harnessId: AgentHarnessID,
        conversationId: AgentConversationID,
        harnessSessionId: AgentSessionID?,
        source: AgentEventSource,
        event: AgentEvent,
        createdAt: Date = Date()
    ) {
        self.generation = generation
        self.index = index
        self.harnessId = harnessId
        self.conversationId = conversationId
        self.harnessSessionId = harnessSessionId
        self.source = source
        self.event = event
        self.createdAt = createdAt
    }

    /// Retains the persisted field names used before the harness terminology update.
    private enum CodingKeys: String, CodingKey {
        case generation
        case index
        case harnessId = "providerId"
        case conversationId
        case harnessSessionId = "providerSessionId"
        case source
        case event
        case createdAt
    }
}

/// Harness-neutral event payload emitted by adapters and runtime services.
public enum AgentEvent: Codable, Equatable, Sendable {
    /// A user, assistant, system, or tool message.
    case message(AgentMessageEvent)
    /// Incremental message text emitted before the harness has completed a message.
    case messageDelta(AgentMessageDeltaEvent)
    /// Harness reasoning or thinking text that hosts may render separately from assistant messages.
    case reasoning(AgentReasoningEvent)
    /// A harness tool invocation.
    case toolCall(AgentToolCallEvent)
    /// A harness tool result.
    case toolResult(AgentToolResultEvent)
    /// Token or model usage update.
    case usage(AgentUsageEvent)
    /// Harness rate-limit state update.
    case rateLimit(AgentRateLimitEvent)
    /// Harness turn or thread activity state changed.
    case activity(AgentActivityEvent)
    /// Harness-reported permission mode changed.
    case permissionMode(AgentPermissionModeEvent)
    /// Harness-neutral collaboration mode changed.
    case collaborationMode(AgentCollaborationModeEvent)
    /// Harness task or todo activity.
    case task(AgentTaskEvent)
    /// Harness-neutral sub-agent lifecycle activity.
    case subAgent(AgentSubAgentEvent)
    /// The harness's full set of live background tasks changed.
    case backgroundTasks(AgentBackgroundTasksEvent)
    /// Harness context compaction lifecycle event.
    case contextCompaction(AgentContextCompactionEvent)
    /// Harness-reported goal state changed.
    case goal(AgentGoalEvent)
    /// Harness session metadata changed.
    case sessionMetadata(AgentSessionMetadataEvent)
    /// Harness session continuity changed during launch.
    case sessionContinuity(AgentSessionContinuityEvent)
    /// Interaction requiring host resolution.
    case interaction(AgentInteractionEvent)
    /// Process lifecycle state.
    case lifecycle(AgentLifecycleEvent)
    /// Non-fatal diagnostic information.
    case diagnostic(AgentDiagnosticEvent)
    /// Raw harness output retained for debugging or compatibility.
    case rawOutput(AgentRawOutputEvent)
}

/// Harness-reported metadata for the active session.
public struct AgentSessionMetadataEvent: Codable, Equatable, Sendable {
    /// Harness session identifier when reported by the harness.
    public let harnessSessionId: AgentSessionID?
    /// User-facing harness session name when reported by the harness.
    public let name: String?
    /// User-facing harness session preview when a full harness name is not available.
    public let preview: String?
    /// Harness-specific metadata for this event.
    public let metadata: [String: JSONValue]

    /// Creates a session metadata event.
    public init(
        harnessSessionId: AgentSessionID? = nil,
        name: String? = nil,
        preview: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.harnessSessionId = harnessSessionId
        self.name = name
        self.preview = preview
        self.metadata = metadata
    }

    /// Decodes a session metadata event, defaulting additive fields for persisted events from older versions.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.harnessSessionId = try container.decodeIfPresent(AgentSessionID.self, forKey: .harnessSessionId)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.preview = try container.decodeIfPresent(String.self, forKey: .preview)
        self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    }

    /// Retains the persisted field names used before the harness terminology update.
    private enum CodingKeys: String, CodingKey {
        case harnessSessionId = "providerSessionId"
        case name
        case preview
        case metadata
    }
}

public extension AgentEvent {
    /// Creates a harness session metadata event.
    static func sessionMetadata(
        harnessSessionId: AgentSessionID? = nil,
        name: String? = nil,
        preview: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) -> Self {
        .sessionMetadata(AgentSessionMetadataEvent(
            harnessSessionId: harnessSessionId,
            name: name,
            preview: preview,
            metadata: metadata
        ))
    }
}

/// Metadata keys for assistant messages that contain a proposed implementation plan.
public enum AgentPlanProposalMetadata {
    /// Boolean metadata key that marks an assistant message as an actionable plan proposal.
    public static let isProposal = "agent_plan_proposal"
    /// Optional stable harness/runtime identifier for the proposed plan.
    public static let proposalId = "agent_plan_proposal_id"
    /// Optional plan markdown. When omitted, runtimes should use the message text.
    public static let planMarkdown = "agent_plan_markdown"
}

/// Metadata keys for user inputs and message events that represent mid-turn steering.
public enum AgentSteeringMetadata {
    /// Boolean metadata key that marks a user input or event as mid-turn steering.
    public static let isSteering = "agent_steering"
    /// Stable host-provided identifier for the local user input that performed the steering.
    public static let inputId = "agent_steering_input_id"
    /// Signal that proved or accepted the steering input.
    public static let signal = "agent_steering_signal"
    /// Codex App Server `item/started` proved the steered user message began.
    public static let signalCodexUserMessageStarted = "codex_user_message_started"
    /// Codex App Server `item/completed` proved the steered user message when `item/started` was not observed.
    public static let signalCodexUserMessageCompleted = "codex_user_message_completed"
    /// Runtime accepted and wrote the steered input to harness stdin.
    public static let signalRuntimeInputAccepted = "runtime_input_accepted"
}

/// Role attached to a message event or message input.
public enum AgentMessageRole: String, Codable, Hashable, Sendable {
    /// Host user input.
    case user
    /// Agent assistant output.
    case assistant
    /// System or developer instruction.
    case system
    /// Tool-sourced message content.
    case tool
}

/// Message content emitted by an agent harness.
public struct AgentMessageEvent: Codable, Equatable, Sendable {
    /// Role of the message author.
    public let role: AgentMessageRole
    /// Text content for the message.
    public let text: String
    /// Harness or runtime metadata for the message.
    public let metadata: [String: JSONValue]

    /// Creates a message event.
    public init(role: AgentMessageRole, text: String, metadata: [String: JSONValue] = [:]) {
        self.role = role
        self.text = text
        self.metadata = metadata
    }

    /// Decodes a message event, defaulting missing metadata for persisted events from older versions.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decode(AgentMessageRole.self, forKey: .role)
        self.text = try container.decode(String.self, forKey: .text)
        self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    }

    /// Encodes the message event.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(metadata, forKey: .metadata)
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case text
        case metadata
    }
}

/// Incremental message content emitted while a harness is streaming.
public struct AgentMessageDeltaEvent: Codable, Equatable, Sendable {
    /// Role of the message being streamed.
    public let role: AgentMessageRole
    /// Text delta content.
    public let text: String
    /// Harness-specific delta metadata.
    public let metadata: [String: JSONValue]

    /// Creates a message delta event.
    public init(role: AgentMessageRole, text: String, metadata: [String: JSONValue] = [:]) {
        self.role = role
        self.text = text
        self.metadata = metadata
    }
}

/// Harness reasoning or thinking content.
public struct AgentReasoningEvent: Codable, Equatable, Sendable {
    /// Reasoning text emitted by the harness.
    public let text: String
    /// Harness-specific reasoning metadata.
    public let metadata: [String: JSONValue]

    /// Creates a reasoning event.
    public init(text: String, metadata: [String: JSONValue] = [:]) {
        self.text = text
        self.metadata = metadata
    }
}

/// Tool call emitted by a harness.
public struct AgentToolCallEvent: Codable, Equatable, Sendable {
    /// Harness-defined tool call identifier.
    public let id: String
    /// Tool name as reported by the harness.
    public let name: String
    /// JSON-compatible tool input.
    public let input: JSONValue
    /// Harness-specific tool call metadata.
    public let metadata: [String: JSONValue]

    /// Creates a tool call event.
    public init(id: String, name: String, input: JSONValue, metadata: [String: JSONValue] = [:]) {
        self.id = id
        self.name = name
        self.input = input
        self.metadata = metadata
    }

    /// Decodes a tool call event, defaulting missing metadata for persisted events from older versions.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.input = try container.decode(JSONValue.self, forKey: .input)
        self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    }

    /// Encodes the tool call event.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(input, forKey: .input)
        try container.encode(metadata, forKey: .metadata)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case input
        case metadata
    }
}

/// Tool result emitted by a harness.
public struct AgentToolResultEvent: Codable, Equatable, Sendable {
    /// Harness-defined tool call identifier.
    public let id: String
    /// Whether the tool result represents an error.
    public let isError: Bool
    /// Textual result content.
    public let content: String
    /// Harness-specific tool result metadata.
    public let metadata: [String: JSONValue]

    /// Creates a tool result event.
    public init(id: String, isError: Bool, content: String, metadata: [String: JSONValue] = [:]) {
        self.id = id
        self.isError = isError
        self.content = content
        self.metadata = metadata
    }

    /// Decodes a tool result event, defaulting missing metadata for persisted events from older versions.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.isError = try container.decode(Bool.self, forKey: .isError)
        self.content = try container.decode(String.self, forKey: .content)
        self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    }

    /// Encodes the tool result event.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(isError, forKey: .isError)
        try container.encode(content, forKey: .content)
        try container.encode(metadata, forKey: .metadata)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case isError
        case content
        case metadata
    }
}

/// Interaction event that requires or records host participation.
public struct AgentInteractionEvent: Codable, Equatable, Sendable {
    /// Interaction identifier used for later resolution.
    public let id: AgentInteractionID
    /// Interaction kind.
    public let kind: AgentInteractionKind
    /// User-facing prompt or summary.
    public let prompt: String
    /// Structured prompt options when the interaction asks a fixed-choice question.
    public let promptOptions: [AgentPromptOption]
    /// Harness-specific metadata.
    public let metadata: [String: JSONValue]

    /// Creates an interaction event.
    public init(
        id: AgentInteractionID,
        kind: AgentInteractionKind,
        prompt: String,
        promptOptions: [AgentPromptOption] = [],
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.prompt = prompt
        self.promptOptions = promptOptions
        self.metadata = metadata
    }

    /// Decodes an interaction event, defaulting additive prompt option fields for older persisted events.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(AgentInteractionID.self, forKey: .id)
        self.kind = try container.decode(AgentInteractionKind.self, forKey: .kind)
        self.prompt = try container.decode(String.self, forKey: .prompt)
        self.promptOptions = try container.decodeIfPresent([AgentPromptOption].self, forKey: .promptOptions) ?? []
        self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    }
}

/// Kind of host interaction requested by a harness or runtime.
public enum AgentInteractionKind: String, Codable, Hashable, Sendable {
    /// Tool approval or denial.
    case approval
    /// Free-form question to the user.
    case prompt
    /// Request to leave planning mode and continue execution.
    case planModeExit
}

/// Process lifecycle event emitted by a runtime.
public struct AgentLifecycleEvent: Codable, Equatable, Sendable {
    /// Lifecycle state.
    public let state: AgentLifecycleState
    /// Optional process exit code.
    public let exitCode: Int32?
    /// Human-readable detail.
    public let message: String?

    /// Creates a lifecycle event.
    public init(state: AgentLifecycleState, exitCode: Int32? = nil, message: String? = nil) {
        self.state = state
        self.exitCode = exitCode
        self.message = message
    }
}

/// Runtime lifecycle states shared by harness adapters.
public enum AgentLifecycleState: String, Codable, Hashable, Sendable {
    /// Process is starting.
    case starting
    /// Process is running.
    case running
    /// Process exited normally.
    case exited
    /// Process was cancelled by the host.
    case cancelled
    /// Process failed before or during execution.
    case failed
}

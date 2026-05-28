import Foundation

/// Source channel that produced an agent event.
public enum AgentEventSource: String, Codable, Hashable, Sendable {
    /// Event decoded from provider stdout.
    case stdout
    /// Diagnostic data decoded or captured from provider stderr.
    case stderr
    /// Process lifecycle event emitted by the runtime.
    case process
    /// Provider hook event emitted through a local hook listener.
    case hook
    /// Internal runtime event emitted by AgentCLIKit.
    case runtime
    /// Host-provided event injected by the app.
    case host
}

/// Provider-neutral event envelope used for replay, persistence, and subscription cursors.
public struct AgentEventEnvelope: Codable, Equatable, Sendable {
    /// Runtime generation for the conversation. Fresh sessions increment this value.
    public let generation: Int
    /// Monotonic event index within a generation.
    public let index: Int
    /// Provider that produced or owns the event.
    public let providerId: AgentProviderID
    /// Host-defined app conversation identifier.
    public let conversationId: AgentConversationID
    /// Provider session identifier when known.
    public let providerSessionId: AgentSessionID?
    /// Source channel for the enclosed event.
    public let source: AgentEventSource
    /// The provider-neutral event payload.
    public let event: AgentEvent
    /// Wall-clock time when the runtime created the envelope.
    public let createdAt: Date

    /// Creates an event envelope.
    public init(
        generation: Int,
        index: Int,
        providerId: AgentProviderID,
        conversationId: AgentConversationID,
        providerSessionId: AgentSessionID?,
        source: AgentEventSource,
        event: AgentEvent,
        createdAt: Date = Date()
    ) {
        self.generation = generation
        self.index = index
        self.providerId = providerId
        self.conversationId = conversationId
        self.providerSessionId = providerSessionId
        self.source = source
        self.event = event
        self.createdAt = createdAt
    }
}

/// Provider-neutral event payload emitted by adapters and runtime services.
public enum AgentEvent: Codable, Equatable, Sendable {
    /// A user, assistant, system, or tool message.
    case message(AgentMessageEvent)
    /// Incremental message text emitted before the provider has completed a message.
    case messageDelta(AgentMessageDeltaEvent)
    /// Provider reasoning or thinking text that hosts may render separately from assistant messages.
    case reasoning(AgentReasoningEvent)
    /// A provider tool invocation.
    case toolCall(AgentToolCallEvent)
    /// A provider tool result.
    case toolResult(AgentToolResultEvent)
    /// Token or model usage update.
    case usage(AgentUsageEvent)
    /// Provider rate-limit state update.
    case rateLimit(AgentRateLimitEvent)
    /// Provider permission mode changed.
    case permissionMode(AgentPermissionModeEvent)
    /// Provider task or sub-agent activity.
    case task(AgentTaskEvent)
    /// Provider session continuity changed during launch.
    case sessionContinuity(AgentSessionContinuityEvent)
    /// Interaction requiring host resolution.
    case interaction(AgentInteractionEvent)
    /// Process lifecycle state.
    case lifecycle(AgentLifecycleEvent)
    /// Non-fatal diagnostic information.
    case diagnostic(AgentDiagnosticEvent)
    /// Raw provider output retained for debugging or compatibility.
    case rawOutput(AgentRawOutputEvent)
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

/// Message content emitted by an agent provider.
public struct AgentMessageEvent: Codable, Equatable, Sendable {
    /// Role of the message author.
    public let role: AgentMessageRole
    /// Text content for the message.
    public let text: String
    /// Provider-specific message metadata.
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

/// Incremental message content emitted while a provider is streaming.
public struct AgentMessageDeltaEvent: Codable, Equatable, Sendable {
    /// Role of the message being streamed.
    public let role: AgentMessageRole
    /// Text delta content.
    public let text: String
    /// Provider-specific delta metadata.
    public let metadata: [String: JSONValue]

    /// Creates a message delta event.
    public init(role: AgentMessageRole, text: String, metadata: [String: JSONValue] = [:]) {
        self.role = role
        self.text = text
        self.metadata = metadata
    }
}

/// Provider reasoning or thinking content.
public struct AgentReasoningEvent: Codable, Equatable, Sendable {
    /// Reasoning text emitted by the provider.
    public let text: String
    /// Provider-specific reasoning metadata.
    public let metadata: [String: JSONValue]

    /// Creates a reasoning event.
    public init(text: String, metadata: [String: JSONValue] = [:]) {
        self.text = text
        self.metadata = metadata
    }
}

/// Tool call emitted by a provider.
public struct AgentToolCallEvent: Codable, Equatable, Sendable {
    /// Provider-defined tool call identifier.
    public let id: String
    /// Tool name as reported by the provider.
    public let name: String
    /// JSON-compatible tool input.
    public let input: JSONValue
    /// Provider-specific tool call metadata.
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

/// Tool result emitted by a provider.
public struct AgentToolResultEvent: Codable, Equatable, Sendable {
    /// Provider-defined tool call identifier.
    public let id: String
    /// Whether the tool result represents an error.
    public let isError: Bool
    /// Textual result content.
    public let content: String
    /// Provider-specific tool result metadata.
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
    /// Provider-specific metadata.
    public let metadata: [String: JSONValue]

    /// Creates an interaction event.
    public init(id: AgentInteractionID, kind: AgentInteractionKind, prompt: String, metadata: [String: JSONValue] = [:]) {
        self.id = id
        self.kind = kind
        self.prompt = prompt
        self.metadata = metadata
    }
}

/// Kind of host interaction requested by a provider or runtime.
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

/// Runtime lifecycle states shared by provider adapters.
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

/// Diagnostic information emitted by a provider or runtime.
public struct AgentDiagnosticEvent: Codable, Equatable, Sendable {
    /// Stable machine-readable code for host UI mapping.
    public let code: AgentDiagnosticCode?
    /// Diagnostic severity.
    public let severity: AgentDiagnosticSeverity
    /// Diagnostic message.
    public let message: String
    /// Provider-specific diagnostic fields.
    public let metadata: [String: JSONValue]

    /// Creates a diagnostic event.
    public init(
        code: AgentDiagnosticCode? = nil,
        severity: AgentDiagnosticSeverity,
        message: String,
        metadata: [String: JSONValue] = [:]
    ) {
        self.code = code
        self.severity = severity
        self.message = message
        self.metadata = metadata
    }

    /// Decodes a diagnostic event, defaulting additive fields for older persisted values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(AgentDiagnosticCode.self, forKey: .code)
        severity = try container.decode(AgentDiagnosticSeverity.self, forKey: .severity)
        message = try container.decode(String.self, forKey: .message)
        metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    }
}

/// Stable machine-readable diagnostic codes for host UI mapping and logging.
public enum AgentDiagnosticCode: String, Codable, Hashable, Sendable {
    /// Provider stderr output forwarded as a diagnostic.
    case providerStderr
    /// Provider stdout could not be decoded.
    case providerDecodeFailed
    /// Provider hook approval failed before it could be resolved.
    case hookApprovalFailed
    /// Provider session persistence failed.
    case sessionStoreSaveFailed
}

/// Severity for diagnostic events.
public enum AgentDiagnosticSeverity: String, Codable, Hashable, Sendable {
    /// Informational diagnostic.
    case info
    /// Warning diagnostic.
    case warning
    /// Error diagnostic.
    case error
}

/// Raw provider output event.
public struct AgentRawOutputEvent: Codable, Equatable, Sendable {
    /// Raw output line or chunk.
    public let text: String
    /// Whether the text was complete at the provider stream boundary.
    public let isComplete: Bool

    /// Creates a raw output event.
    public init(text: String, isComplete: Bool) {
        self.text = text
        self.isComplete = isComplete
    }
}

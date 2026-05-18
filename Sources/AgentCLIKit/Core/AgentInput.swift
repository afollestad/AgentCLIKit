import Foundation

/// Input sent from a host application to an agent runtime.
public enum AgentInput: Codable, Equatable, Sendable {
    /// User-authored message to continue a session.
    case userMessage(AgentMessageInput)
    /// Request to interrupt the provider process.
    case interrupt(AgentInterruptInput)
    /// Resolution for a pending interaction.
    case interactionResolution(AgentInteractionResolution)
}

/// User message input for an agent session.
public struct AgentMessageInput: Codable, Equatable, Sendable {
    /// Message text.
    public let text: String
    /// Optional attachments the provider adapter may encode or reference.
    public let attachments: [AgentInputAttachment]
    /// Provider-neutral metadata for adapters that support richer input.
    public let metadata: [String: JSONValue]

    /// Creates a message input.
    public init(text: String, attachments: [AgentInputAttachment] = [], metadata: [String: JSONValue] = [:]) {
        self.text = text
        self.attachments = attachments
        self.metadata = metadata
    }
}

/// File or data attachment associated with a user message.
public struct AgentInputAttachment: Codable, Equatable, Sendable {
    /// Stable attachment identifier.
    public let id: String
    /// Local file URL when the attachment lives on disk.
    public let fileURL: URL?
    /// Media type or provider-neutral type hint.
    public let type: String

    /// Creates an input attachment.
    public init(id: String, fileURL: URL?, type: String) {
        self.id = id
        self.fileURL = fileURL
        self.type = type
    }
}

/// Interrupt input sent to a running provider process.
public struct AgentInterruptInput: Codable, Equatable, Sendable {
    /// Human-readable reason for interruption.
    public let reason: String?

    /// Creates an interrupt input.
    public init(reason: String? = nil) {
        self.reason = reason
    }
}

/// Host resolution for a pending provider or runtime interaction.
public struct AgentInteractionResolution: Codable, Equatable, Sendable {
    /// Interaction being resolved.
    public let id: AgentInteractionID
    /// Resolution outcome.
    public let outcome: AgentInteractionOutcome
    /// Optional text supplied by the host or user.
    public let responseText: String?
    /// Provider-neutral metadata for adapter-specific resolution fields.
    public let metadata: [String: JSONValue]

    /// Creates an interaction resolution.
    public init(
        id: AgentInteractionID,
        outcome: AgentInteractionOutcome,
        responseText: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.outcome = outcome
        self.responseText = responseText
        self.metadata = metadata
    }
}

/// Outcome chosen by the host for an interaction.
public enum AgentInteractionOutcome: String, Codable, Hashable, Sendable {
    /// Allow the requested operation.
    case approved
    /// Deny the requested operation.
    case denied
    /// Defer the decision to provider fallback behavior.
    case deferred
    /// Submit free-form text.
    case answered
    /// Cancel the interaction.
    case cancelled
}

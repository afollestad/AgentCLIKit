import Foundation

/// Approval request surfaced by a provider or hook.
public struct AgentApprovalRequest: Codable, Equatable, Sendable {
    /// Interaction identifier resolved by the host.
    public let id: AgentInteractionID
    /// Provider that requested approval.
    public let providerId: AgentProviderID
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Operation or tool name requiring approval.
    public let operation: String
    /// User-facing reason or summary.
    public let reason: String
    /// JSON-compatible operation input.
    public let input: JSONValue
    /// Date the request was created.
    public let createdAt: Date

    /// Creates an approval request.
    public init(
        id: AgentInteractionID,
        providerId: AgentProviderID,
        conversationId: AgentConversationID,
        operation: String,
        reason: String,
        input: JSONValue,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.providerId = providerId
        self.conversationId = conversationId
        self.operation = operation
        self.reason = reason
        self.input = input
        self.createdAt = createdAt
    }
}

/// Prompt request asking the host to collect free-form user input.
public struct AgentPromptRequest: Codable, Equatable, Sendable {
    /// Interaction identifier resolved by the host.
    public let id: AgentInteractionID
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// User-facing prompt text.
    public let prompt: String
    /// Optional default answer.
    public let defaultResponse: String?

    /// Creates a prompt request.
    public init(
        id: AgentInteractionID,
        conversationId: AgentConversationID,
        prompt: String,
        defaultResponse: String? = nil
    ) {
        self.id = id
        self.conversationId = conversationId
        self.prompt = prompt
        self.defaultResponse = defaultResponse
    }
}

/// Stored interaction record and optional host resolution.
public struct AgentInteractionRecord: Codable, Equatable, Sendable {
    /// Interaction identifier.
    public let id: AgentInteractionID
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Interaction kind.
    public let kind: AgentInteractionKind
    /// Optional approval request details.
    public let approvalRequest: AgentApprovalRequest?
    /// Optional prompt request details.
    public let promptRequest: AgentPromptRequest?
    /// Host resolution when available.
    public let resolution: AgentInteractionResolution?
    /// Last update date.
    public let updatedAt: Date

    /// Creates an interaction record.
    public init(
        id: AgentInteractionID,
        conversationId: AgentConversationID,
        kind: AgentInteractionKind,
        approvalRequest: AgentApprovalRequest? = nil,
        promptRequest: AgentPromptRequest? = nil,
        resolution: AgentInteractionResolution? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.conversationId = conversationId
        self.kind = kind
        self.approvalRequest = approvalRequest
        self.promptRequest = promptRequest
        self.resolution = resolution
        self.updatedAt = updatedAt
    }
}

/// Store for pending and resolved host interactions.
public protocol AgentInteractionStore: Sendable {
    /// Saves or replaces an interaction record.
    func save(_ record: AgentInteractionRecord) async
    /// Resolves an interaction.
    func resolve(_ resolution: AgentInteractionResolution, updatedAt: Date) async
    /// Returns an interaction by identifier.
    func record(id: AgentInteractionID) async -> AgentInteractionRecord?
    /// Returns unresolved interactions for a conversation.
    func pending(conversationId: AgentConversationID) async -> [AgentInteractionRecord]
}

/// In-memory interaction store.
public actor InMemoryAgentInteractionStore: AgentInteractionStore {
    private var records: [AgentInteractionID: AgentInteractionRecord] = [:]

    /// Creates an in-memory interaction store.
    public init(records: [AgentInteractionRecord] = []) {
        self.records = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
    }

    /// Saves or replaces an interaction record.
    public func save(_ record: AgentInteractionRecord) async {
        records[record.id] = record
    }

    /// Resolves an interaction.
    public func resolve(_ resolution: AgentInteractionResolution, updatedAt: Date = Date()) async {
        guard let existing = records[resolution.id] else {
            return
        }
        records[resolution.id] = AgentInteractionRecord(
            id: existing.id,
            conversationId: existing.conversationId,
            kind: existing.kind,
            approvalRequest: existing.approvalRequest,
            promptRequest: existing.promptRequest,
            resolution: resolution,
            updatedAt: updatedAt
        )
    }

    /// Returns an interaction by identifier.
    public func record(id: AgentInteractionID) async -> AgentInteractionRecord? {
        records[id]
    }

    /// Returns unresolved interactions for a conversation.
    public func pending(conversationId: AgentConversationID) async -> [AgentInteractionRecord] {
        records.values
            .filter { $0.conversationId == conversationId && $0.resolution == nil }
            .sorted { $0.updatedAt < $1.updatedAt }
    }
}

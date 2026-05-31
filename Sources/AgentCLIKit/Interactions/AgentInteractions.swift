import Foundation

/// Approval request surfaced by a provider or hook.
public struct AgentApprovalRequest: Codable, Equatable, Sendable {
    /// Interaction identifier resolved by the host.
    public let id: AgentInteractionID
    /// Provider that requested approval.
    public let providerId: AgentProviderID
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Provider session identifier when known.
    public let providerSessionId: AgentSessionID?
    /// Operation or tool name requiring approval.
    public let operation: String
    /// User-facing reason or summary.
    public let reason: String
    /// JSON-compatible operation input.
    public let input: JSONValue
    /// Provider permission mode active when the approval was requested.
    public let permissionMode: String?
    /// Date the request was created.
    public let createdAt: Date

    /// Creates an approval request.
    public init(
        id: AgentInteractionID,
        providerId: AgentProviderID,
        conversationId: AgentConversationID,
        providerSessionId: AgentSessionID? = nil,
        operation: String,
        reason: String,
        input: JSONValue,
        permissionMode: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.providerId = providerId
        self.conversationId = conversationId
        self.providerSessionId = providerSessionId
        self.operation = operation
        self.reason = reason
        self.input = input
        self.permissionMode = permissionMode
        self.createdAt = createdAt
    }

    /// Decodes an approval request, defaulting additive fields for older persisted records.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(AgentInteractionID.self, forKey: .id)
        self.providerId = try container.decode(AgentProviderID.self, forKey: .providerId)
        self.conversationId = try container.decode(AgentConversationID.self, forKey: .conversationId)
        self.providerSessionId = try container.decodeIfPresent(AgentSessionID.self, forKey: .providerSessionId)
        self.operation = try container.decode(String.self, forKey: .operation)
        self.reason = try container.decode(String.self, forKey: .reason)
        self.input = try container.decode(JSONValue.self, forKey: .input)
        self.permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    /// Concise host-facing summary for approval lists, notifications, and copy affordances.
    public var conciseSummary: String {
        let candidate: String?
        switch operation {
        case "Bash":
            candidate = stringInput("command")
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            candidate = stringInput("file_path") ?? stringInput("path") ?? stringInput("notebook_path")
        case "EnterPlanMode":
            candidate = "Switch the session into plan mode"
        case "ExitPlanMode":
            candidate = "Present the plan and leave plan mode"
        default:
            candidate = stringInput("file_path") ?? stringInput("path") ?? stringInput("command")
        }
        return Self.truncated(
            candidate?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "Review requested tool input"
        )
    }

    /// Markdown plan included in an `ExitPlanMode` approval input.
    public var planMarkdown: String? {
        guard operation == "ExitPlanMode" else {
            return nil
        }
        return stringInput("plan")?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Session approval scopes available for this approval.
    public var supportedSessionApprovalScopes: [AgentToolApprovalSessionScope] {
        sessionApprovalRequest?.supportedSessionApprovalScopes ?? []
    }

    /// Provider-neutral session approval request for this approval when enough metadata is available.
    public var sessionApprovalRequest: AgentSessionApprovalRequest? {
        guard let providerSessionId else {
            return nil
        }
        return AgentSessionApprovalRequest(
            providerId: providerId,
            conversationId: conversationId,
            sessionId: providerSessionId,
            toolName: operation,
            toolInput: input
        )
    }

    private func stringInput(_ key: String) -> String? {
        guard case let .object(object) = input,
              case let .string(value)? = object[key] else {
            return nil
        }
        return value
    }

    private static func truncated(_ value: String, limit: Int = 140) -> String {
        guard value.count > limit else {
            return value
        }
        return String(value.prefix(limit - 1)) + "..."
    }
}

/// Prompt request asking the host to collect free-form user input.
public struct AgentPromptRequest: Codable, Equatable, Sendable {
    /// Interaction identifier resolved by the host.
    public let id: AgentInteractionID
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Provider session identifier when known.
    public let providerSessionId: AgentSessionID?
    /// User-facing prompt text.
    public let prompt: String
    /// Optional default answer.
    public let defaultResponse: String?
    /// Structured answer options when the provider asks a fixed-choice question.
    public let options: [AgentPromptOption]
    /// Whether the host may submit text that is not one of `options`.
    public let allowsCustomResponse: Bool

    /// Creates a prompt request.
    public init(
        id: AgentInteractionID,
        conversationId: AgentConversationID,
        providerSessionId: AgentSessionID? = nil,
        prompt: String,
        defaultResponse: String? = nil,
        options: [AgentPromptOption] = [],
        allowsCustomResponse: Bool = true
    ) {
        self.id = id
        self.conversationId = conversationId
        self.providerSessionId = providerSessionId
        self.prompt = prompt
        self.defaultResponse = defaultResponse
        self.options = options
        self.allowsCustomResponse = allowsCustomResponse
    }

    /// Decodes a prompt request, defaulting additive fields for older persisted records.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(AgentInteractionID.self, forKey: .id)
        self.conversationId = try container.decode(AgentConversationID.self, forKey: .conversationId)
        self.providerSessionId = try container.decodeIfPresent(AgentSessionID.self, forKey: .providerSessionId)
        self.prompt = try container.decode(String.self, forKey: .prompt)
        self.defaultResponse = try container.decodeIfPresent(String.self, forKey: .defaultResponse)
        self.options = try container.decodeIfPresent([AgentPromptOption].self, forKey: .options) ?? []
        self.allowsCustomResponse = try container.decodeIfPresent(Bool.self, forKey: .allowsCustomResponse) ?? true
    }
}

/// One selectable answer for a structured provider prompt.
public struct AgentPromptOption: Codable, Equatable, Sendable, Identifiable {
    /// Stable option identifier used when resolving the prompt.
    public let id: String
    /// User-facing option label.
    public let label: String
    /// Text sent back to the provider when this option is selected.
    public let responseText: String
    /// Provider-neutral option metadata.
    public let metadata: [String: JSONValue]

    /// Creates a prompt option.
    public init(id: String, label: String, responseText: String, metadata: [String: JSONValue] = [:]) {
        self.id = id
        self.label = label
        self.responseText = responseText
        self.metadata = metadata
    }
}

/// Source of an answer submitted for a provider prompt.
public enum AgentPromptAnswerSource: Codable, Equatable, Sendable {
    /// A fixed prompt option was selected.
    case option(id: String)
    /// User-authored text was supplied.
    case customResponse
}

/// Host answer for a pending provider prompt.
public struct AgentPromptAnswer: Codable, Equatable, Sendable {
    /// Interaction being answered.
    public let interactionId: AgentInteractionID
    /// Answer text sent to the provider.
    public let responseText: String
    /// Whether the answer came from a fixed option or custom input.
    public let source: AgentPromptAnswerSource
    /// Provider-neutral answer metadata.
    public let metadata: [String: JSONValue]

    /// Creates a prompt answer.
    public init(
        interactionId: AgentInteractionID,
        responseText: String,
        source: AgentPromptAnswerSource,
        metadata: [String: JSONValue] = [:]
    ) {
        self.interactionId = interactionId
        self.responseText = responseText
        self.source = source
        self.metadata = metadata
    }

    /// Converts the answer into a generic interaction resolution.
    public func resolution() -> AgentInteractionResolution {
        var resolutionMetadata = metadata
        switch source {
        case let .option(id):
            resolutionMetadata["prompt_answer_source"] = .string("option")
            resolutionMetadata["prompt_option_id"] = .string(id)
        case .customResponse:
            resolutionMetadata["prompt_answer_source"] = .string("customResponse")
        }
        return AgentInteractionResolution(
            id: interactionId,
            outcome: .answered,
            responseText: responseText,
            metadata: resolutionMetadata
        )
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
        // Resolution is terminal; late hook publishes must not reopen host approval UI.
        if records[record.id]?.resolution != nil {
            return
        }
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

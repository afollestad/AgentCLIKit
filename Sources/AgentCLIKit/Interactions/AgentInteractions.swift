import Foundation

/// Approval request surfaced by a harness or hook.
public struct AgentApprovalRequest: Codable, Equatable, Sendable {
    /// Interaction identifier resolved by the host.
    public let id: AgentInteractionID
    /// Harness that requested approval.
    public let harnessId: AgentHarnessID
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Harness session identifier when known.
    public let harnessSessionId: AgentSessionID?
    /// Operation or tool name requiring approval.
    public let operation: String
    /// User-facing reason or summary.
    public let reason: String
    /// JSON-compatible operation input.
    public let input: JSONValue
    /// Canonical operation input used for approval identity, when available.
    public let approvalIdentityInput: JSONValue?
    /// Harness permission mode active when the approval was requested.
    public let permissionMode: String?
    /// Date the request was created.
    public let createdAt: Date

    /// Creates an approval request.
    public init(
        id: AgentInteractionID,
        harnessId: AgentHarnessID,
        conversationId: AgentConversationID,
        harnessSessionId: AgentSessionID? = nil,
        operation: String,
        reason: String,
        input: JSONValue,
        approvalIdentityInput: JSONValue? = nil,
        permissionMode: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.harnessId = harnessId
        self.conversationId = conversationId
        self.harnessSessionId = harnessSessionId
        self.operation = operation
        self.reason = reason
        self.input = input
        self.approvalIdentityInput = approvalIdentityInput
        self.permissionMode = permissionMode
        self.createdAt = createdAt
    }

    /// Decodes an approval request, defaulting additive fields for older persisted records.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(AgentInteractionID.self, forKey: .id)
        self.harnessId = try container.decode(AgentHarnessID.self, forKey: .harnessId)
        self.conversationId = try container.decode(AgentConversationID.self, forKey: .conversationId)
        self.harnessSessionId = try container.decodeIfPresent(AgentSessionID.self, forKey: .harnessSessionId)
        self.operation = try container.decode(String.self, forKey: .operation)
        self.reason = try container.decode(String.self, forKey: .reason)
        self.input = try container.decode(JSONValue.self, forKey: .input)
        self.approvalIdentityInput = try container.decodeIfPresent(JSONValue.self, forKey: .approvalIdentityInput)
        self.permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    /// Concise host-facing summary for approval lists, notifications, and copy affordances.
    public var conciseSummary: String {
        let candidate: String?
        switch operation {
        case "Bash":
            candidate = identityStringInput("command") ?? stringInput("command")
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

    /// Session approval scope that is safe to preselect for this request, when available.
    public var recommendedSessionApprovalScope: AgentToolApprovalSessionScope? {
        sessionApprovalRequest?.recommendedSessionApprovalScope
    }

    /// Harness-neutral session approval request for this approval when enough metadata is available.
    public var sessionApprovalRequest: AgentSessionApprovalRequest? {
        guard let harnessSessionId else {
            return nil
        }
        return AgentSessionApprovalRequest(
            harnessId: harnessId,
            conversationId: conversationId,
            sessionId: harnessSessionId,
            toolName: operation,
            toolInput: input,
            approvalIdentityToolInput: approvalIdentityInput
        )
    }

    private func stringInput(_ key: String) -> String? {
        guard case let .object(object) = input,
              case let .string(value)? = object[key] else {
            return nil
        }
        return value
    }

    private func identityStringInput(_ key: String) -> String? {
        guard case let .object(object)? = approvalIdentityInput,
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

    /// Retains the persisted field names used before the harness terminology update.
    private enum CodingKeys: String, CodingKey {
        case id
        case harnessId = "providerId"
        case conversationId
        case harnessSessionId = "providerSessionId"
        case operation
        case reason
        case input
        case approvalIdentityInput
        case permissionMode
        case createdAt
    }
}

/// Prompt request asking the host to collect free-form user input.
public struct AgentPromptRequest: Codable, Equatable, Sendable {
    /// Interaction identifier resolved by the host.
    public let id: AgentInteractionID
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Harness session identifier when known.
    public let harnessSessionId: AgentSessionID?
    /// User-facing prompt text.
    public let prompt: String
    /// Optional default answer.
    public let defaultResponse: String?
    /// Structured answer options when the harness asks a fixed-choice question.
    public let options: [AgentPromptOption]
    /// Whether the host may submit text that is not one of `options`.
    public let allowsCustomResponse: Bool

    /// Creates a prompt request.
    public init(
        id: AgentInteractionID,
        conversationId: AgentConversationID,
        harnessSessionId: AgentSessionID? = nil,
        prompt: String,
        defaultResponse: String? = nil,
        options: [AgentPromptOption] = [],
        allowsCustomResponse: Bool = true
    ) {
        self.id = id
        self.conversationId = conversationId
        self.harnessSessionId = harnessSessionId
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
        self.harnessSessionId = try container.decodeIfPresent(AgentSessionID.self, forKey: .harnessSessionId)
        self.prompt = try container.decode(String.self, forKey: .prompt)
        self.defaultResponse = try container.decodeIfPresent(String.self, forKey: .defaultResponse)
        self.options = try container.decodeIfPresent([AgentPromptOption].self, forKey: .options) ?? []
        self.allowsCustomResponse = try container.decodeIfPresent(Bool.self, forKey: .allowsCustomResponse) ?? true
    }

    /// Retains the persisted field names used before the harness terminology update.
    private enum CodingKeys: String, CodingKey {
        case id
        case conversationId
        case harnessSessionId = "providerSessionId"
        case prompt
        case defaultResponse
        case options
        case allowsCustomResponse
    }
}

/// One selectable answer for a structured harness prompt.
public struct AgentPromptOption: Codable, Equatable, Sendable, Identifiable {
    /// Stable option identifier used when resolving the prompt.
    public let id: String
    /// User-facing option label.
    public let label: String
    /// Optional user-facing description for the option.
    public let description: String?
    /// Text sent back to the harness when this option is selected.
    public let responseText: String
    /// Harness-neutral option metadata.
    public let metadata: [String: JSONValue]

    /// Creates a prompt option.
    public init(
        id: String,
        label: String,
        description: String? = nil,
        responseText: String,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.responseText = responseText
        self.metadata = metadata
    }

    /// Decodes prompt options, defaulting additive fields for older persisted records.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.label = try container.decode(String.self, forKey: .label)
        self.responseText = try container.decode(String.self, forKey: .responseText)
        let metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
        self.metadata = metadata
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
            ?? Self.description(from: metadata)
    }

    private static func description(from metadata: [String: JSONValue]) -> String? {
        guard case let .string(value)? = metadata["description"], !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// Source of an answer submitted for a harness prompt.
public enum AgentPromptAnswerSource: Codable, Equatable, Sendable {
    /// A fixed prompt option was selected.
    case option(id: String)
    /// User-authored text was supplied.
    case customResponse
}

/// Host answer for a pending harness prompt.
public struct AgentPromptAnswer: Codable, Equatable, Sendable {
    /// Interaction being answered.
    public let interactionId: AgentInteractionID
    /// Answer text sent to the harness.
    public let responseText: String
    /// Whether the answer came from a fixed option or custom input.
    public let source: AgentPromptAnswerSource
    /// Harness-neutral answer metadata.
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

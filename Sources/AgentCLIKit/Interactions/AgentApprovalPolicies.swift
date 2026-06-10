import Foundation

/// Reusable approval grant category understood by provider adapters.
public enum AgentApprovalGrantKind: String, Codable, Hashable, Sendable {
    /// Grant applies to one pending interaction.
    case oneShot
    /// Grant applies to equivalent requests during the current runtime session.
    case session
    /// Grant applies to a batch of related pending interactions.
    case batch
}

/// Durable session approval match kinds shared by provider hook implementations.
public enum AgentSessionApprovalMatchKind: String, Codable, Hashable, Sendable {
    /// Exact Bash command match.
    case bashExact
    /// Conservative Bash executable plus subcommand match.
    case bashCommandGroup
    /// Exact file path match for file-mutating tools.
    case filePathExact
}

/// Tool approval scope the host may offer for a pending approval.
public enum AgentToolApprovalSessionScope: String, Codable, Hashable, Sendable {
    /// Approve only the exact operation payload.
    case exact
    /// Approve a conservative group of similar operations.
    case group
}

/// Durable approval grant for a provider session.
public struct AgentSessionApprovalGrant: Codable, Equatable, Hashable, Sendable {
    /// Provider that owns the approval.
    public let providerId: AgentProviderID
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Provider session identifier.
    public let sessionId: AgentSessionID
    /// Match kind used by the provider hook.
    public let matchKind: AgentSessionApprovalMatchKind
    /// Normalized value for `matchKind`.
    public let matchValue: String

    /// Creates a durable session approval grant.
    public init(
        providerId: AgentProviderID,
        conversationId: AgentConversationID,
        sessionId: AgentSessionID,
        matchKind: AgentSessionApprovalMatchKind,
        matchValue: String
    ) {
        self.providerId = providerId
        self.conversationId = conversationId
        self.sessionId = sessionId
        self.matchKind = matchKind
        self.matchValue = matchValue
    }
}

/// Result of recording a durable session approval.
public struct AgentSessionApprovalRecordResult: Codable, Equatable, Sendable {
    /// Whether the approval can be used by future matching requests.
    public let isEffective: Bool
    /// Whether a new record was inserted.
    public let wasInserted: Bool

    /// Creates a session approval record result.
    public init(isEffective: Bool, wasInserted: Bool) {
        self.isEffective = isEffective
        self.wasInserted = wasInserted
    }
}

/// Provider-neutral request used to derive or match durable session approvals.
public struct AgentSessionApprovalRequest: Codable, Equatable, Sendable {
    /// Provider that owns the approval.
    public let providerId: AgentProviderID
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Provider session identifier.
    public let sessionId: AgentSessionID
    /// Provider tool name.
    public let toolName: String
    /// JSON-compatible tool input.
    public let toolInput: JSONValue

    /// Creates a durable session approval request.
    public init(
        providerId: AgentProviderID,
        conversationId: AgentConversationID,
        sessionId: AgentSessionID,
        toolName: String,
        toolInput: JSONValue
    ) {
        self.providerId = providerId
        self.conversationId = conversationId
        self.sessionId = sessionId
        self.toolName = toolName
        self.toolInput = toolInput
    }

    /// Session approval scopes supported by this request.
    public var supportedSessionApprovalScopes: [AgentToolApprovalSessionScope] {
        switch toolName {
        case "Bash":
            var scopes: [AgentToolApprovalSessionScope] = []
            if sessionApprovalGrant(for: .exact) != nil {
                scopes.append(.exact)
            }
            if sessionApprovalGrant(for: .group) != nil {
                scopes.append(.group)
            }
            return scopes
        case "Write", "Edit", "MultiEdit", "NotebookEdit", "Read", "LS", "NotebookRead":
            return sessionApprovalGrant(for: .exact) == nil ? [] : [.exact]
        default:
            return []
        }
    }

    /// Session approval scope that is safe to preselect for this request, when available.
    public var recommendedSessionApprovalScope: AgentToolApprovalSessionScope? {
        switch toolName {
        case "Bash":
            return recommendedBashCommandGroup == nil ? nil : .group
        default:
            return nil
        }
    }

    /// Builds a durable grant for a supported session approval scope.
    public func sessionApprovalGrant(for scope: AgentToolApprovalSessionScope) -> AgentSessionApprovalGrant? {
        switch (toolName, scope) {
        case ("Bash", .exact):
            guard let command = normalizedBashCommand else {
                return nil
            }
            return grant(matchKind: .bashExact, matchValue: command)
        case ("Bash", .group):
            guard let commandGroup = bashCommandGroup else {
                return nil
            }
            return grant(matchKind: .bashCommandGroup, matchValue: commandGroup)
        case ("Write", .exact), ("Edit", .exact), ("MultiEdit", .exact), ("NotebookEdit", .exact),
             ("Read", .exact), ("LS", .exact), ("NotebookRead", .exact):
            guard let path = normalizedApprovalPath else {
                return nil
            }
            return grant(matchKind: .filePathExact, matchValue: path)
        default:
            return nil
        }
    }

    private func grant(matchKind: AgentSessionApprovalMatchKind, matchValue: String) -> AgentSessionApprovalGrant {
        AgentSessionApprovalGrant(
            providerId: providerId,
            conversationId: conversationId,
            sessionId: sessionId,
            matchKind: matchKind,
            matchValue: matchValue
        )
    }

    private var normalizedApprovalPath: String? {
        (stringInput("file_path") ?? stringInput("path") ?? stringInput("notebook_path"))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}

/// Provider-neutral approval selection chosen by a host.
public struct AgentApprovalSelection: Codable, Equatable, Sendable {
    /// Interaction being resolved.
    public let interactionId: AgentInteractionID
    /// Provider that owns the approval when known.
    public let providerId: AgentProviderID?
    /// Whether the operation is approved or denied.
    public let outcome: AgentInteractionOutcome
    /// Grant category for approved operations.
    public let grantKind: AgentApprovalGrantKind
    /// Optional provider operation name to reuse for session approvals.
    public let operation: String?
    /// Optional user-facing reason.
    public let reason: String?
    /// Provider-neutral selection metadata.
    public let metadata: [String: JSONValue]

    /// Creates an approval selection.
    public init(
        interactionId: AgentInteractionID,
        providerId: AgentProviderID? = nil,
        outcome: AgentInteractionOutcome,
        grantKind: AgentApprovalGrantKind = .oneShot,
        operation: String? = nil,
        reason: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.interactionId = interactionId
        self.providerId = providerId
        self.outcome = outcome
        self.grantKind = grantKind
        self.operation = operation
        self.reason = reason
        self.metadata = metadata
    }

    /// Converts the selection into a generic interaction resolution.
    public func resolution() -> AgentInteractionResolution {
        var resolutionMetadata = metadata
        resolutionMetadata["approval_grant_kind"] = .string(grantKind.rawValue)
        if let providerId {
            resolutionMetadata["approval_provider_id"] = .string(providerId.rawValue)
        }
        if let operation {
            resolutionMetadata["approval_operation"] = .string(operation)
        }
        return AgentInteractionResolution(
            id: interactionId,
            outcome: outcome,
            responseText: reason,
            metadata: resolutionMetadata
        )
    }
}

/// Durable approval policy boundary that hosts may back with app persistence.
public protocol AgentApprovalPolicyStore: Sendable {
    /// Records an approval selection for later policy checks.
    func save(_ selection: AgentApprovalSelection) async
    /// Returns whether the operation is approved for the current session.
    func isApprovedForSession(providerId: AgentProviderID, operation: String) async -> Bool
    /// Returns and consumes a one-shot approval for the interaction when present.
    func consumeOneShotApproval(id: AgentInteractionID) async -> AgentApprovalSelection?
}

/// Store for durable session approval grants.
public protocol AgentSessionApprovalPolicyStore: Sendable {
    /// Records a durable session approval.
    func recordSessionApproval(_ grant: AgentSessionApprovalGrant) async -> AgentSessionApprovalRecordResult
    /// Removes one durable session approval.
    func discardSessionApproval(_ grant: AgentSessionApprovalGrant) async
    /// Returns whether a request matches a stored durable approval.
    func allowsSessionApproval(_ request: AgentSessionApprovalRequest) async -> Bool
    /// Removes durable approvals for a provider session.
    func removeSessionApprovals(
        providerId: AgentProviderID,
        conversationId: AgentConversationID,
        sessionId: AgentSessionID
    ) async
}

/// In-memory approval policy store suitable for tests and demos.
public actor InMemoryAgentApprovalPolicyStore: AgentApprovalPolicyStore, AgentSessionApprovalPolicyStore {
    private var sessionApprovals: Set<SessionApprovalKey> = []
    private var sessionApprovalGrants: Set<AgentSessionApprovalGrant> = []
    private var oneShotApprovals: [AgentInteractionID: AgentApprovalSelection] = [:]

    /// Creates an in-memory approval policy store.
    public init() {}

    /// Records an approval selection for later policy checks.
    public func save(_ selection: AgentApprovalSelection) async {
        guard selection.outcome == .approved else {
            return
        }
        switch selection.grantKind {
        case .oneShot, .batch:
            oneShotApprovals[selection.interactionId] = selection
        case .session:
            if let operation = selection.operation {
                sessionApprovals.insert(SessionApprovalKey(providerId: selection.providerId?.rawValue, operation: operation))
            }
        }
    }

    /// Returns whether the operation is approved for the current session.
    public func isApprovedForSession(providerId: AgentProviderID, operation: String) async -> Bool {
        sessionApprovals.contains(SessionApprovalKey(providerId: providerId.rawValue, operation: operation))
            || sessionApprovals.contains(SessionApprovalKey(providerId: nil, operation: operation))
    }

    /// Returns and consumes a one-shot approval for the interaction when present.
    public func consumeOneShotApproval(id: AgentInteractionID) async -> AgentApprovalSelection? {
        oneShotApprovals.removeValue(forKey: id)
    }

    /// Records a durable session approval.
    public func recordSessionApproval(_ grant: AgentSessionApprovalGrant) async -> AgentSessionApprovalRecordResult {
        let inserted = sessionApprovalGrants.insert(grant).inserted
        return AgentSessionApprovalRecordResult(isEffective: true, wasInserted: inserted)
    }

    /// Removes one durable session approval.
    public func discardSessionApproval(_ grant: AgentSessionApprovalGrant) async {
        sessionApprovalGrants.remove(grant)
    }

    /// Returns whether a request matches a stored durable approval.
    public func allowsSessionApproval(_ request: AgentSessionApprovalRequest) async -> Bool {
        request.supportedSessionApprovalScopes
            .compactMap { request.sessionApprovalGrant(for: $0) }
            .contains { sessionApprovalGrants.contains($0) }
    }

    /// Removes durable approvals for a provider session.
    public func removeSessionApprovals(
        providerId: AgentProviderID,
        conversationId: AgentConversationID,
        sessionId: AgentSessionID
    ) async {
        sessionApprovalGrants = sessionApprovalGrants.filter {
            $0.providerId != providerId || $0.conversationId != conversationId || $0.sessionId != sessionId
        }
    }

    private struct SessionApprovalKey: Hashable {
        let providerId: String?
        let operation: String
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

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

/// In-memory approval policy store suitable for tests and demos.
public actor InMemoryAgentApprovalPolicyStore: AgentApprovalPolicyStore {
    private var sessionApprovals: Set<SessionApprovalKey> = []
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

    private struct SessionApprovalKey: Hashable {
        let providerId: String?
        let operation: String
    }
}

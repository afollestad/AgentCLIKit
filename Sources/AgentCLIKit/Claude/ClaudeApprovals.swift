import Foundation

/// Claude approval decision returned to hook callers.
public enum ClaudeApprovalDecision: String, Codable, Equatable, Sendable {
    /// Allow the operation.
    case allow
    /// Deny the operation.
    case deny
    /// Defer to Claude fallback behavior.
    case deferDecision
}

/// Complete Claude hook decision payload returned by live decision providers.
public struct ClaudeHookDecision: Codable, Equatable, Sendable {
    /// Permission decision returned to Claude.
    public let approval: ClaudeApprovalDecision
    /// Optional human-readable reason returned to Claude.
    public let reason: String?
    /// Optional replacement tool input returned for Claude tools that require echoed or augmented input.
    public let updatedInput: JSONValue?

    /// Creates a Claude hook decision.
    public init(approval: ClaudeApprovalDecision, reason: String? = nil, updatedInput: JSONValue? = nil) {
        self.approval = approval
        self.reason = reason
        self.updatedInput = updatedInput
    }

    /// Convenience allow decision.
    public static func allow(reason: String? = nil, updatedInput: JSONValue? = nil) -> ClaudeHookDecision {
        ClaudeHookDecision(approval: .allow, reason: reason, updatedInput: updatedInput)
    }

    /// Convenience deny decision.
    public static func deny(reason: String? = nil) -> ClaudeHookDecision {
        ClaudeHookDecision(approval: .deny, reason: reason)
    }

    /// Convenience defer decision.
    public static var deferDecision: ClaudeHookDecision {
        ClaudeHookDecision(approval: .deferDecision)
    }
}

/// Session-scoped key for transient Claude hook decisions.
public struct ClaudeTransientDecisionKey: Codable, Hashable, Sendable {
    /// Provider session that emitted the hook, when known.
    public let sessionId: AgentSessionID?
    /// Hook interaction identifier, usually Claude's tool use ID.
    public let interactionId: AgentInteractionID

    /// Creates a scoped transient decision key.
    public init(sessionId: AgentSessionID?, interactionId: AgentInteractionID) {
        self.sessionId = sessionId
        self.interactionId = interactionId
    }
}

/// Store used by Claude hooks for reusable and one-shot approval policy decisions.
public protocol ClaudeApprovalPolicyStoring: AgentSessionApprovalPolicyStore {
    /// Approves an operation for the rest of the session.
    func approveForSession(operation: String) async
    /// Approves an operation input for the rest of the session.
    func approveForSession(operation: String, input: JSONValue) async
    /// Returns whether an operation is approved for the session.
    func isSessionApproved(operation: String) async -> Bool
    /// Returns whether an operation input is approved for the session.
    func isSessionApproved(operation: String, input: JSONValue) async -> Bool
    /// Adds transient one-shot approvals.
    func approveBatch(_ ids: [AgentInteractionID]) async
    /// Consumes and removes a transient approval.
    func consumeTransientApproval(id: AgentInteractionID) async -> Bool
}

/// Optional store contract for transient hook decisions that can carry denial or updated input.
public protocol ClaudeTransientDecisionStoring: Sendable {
    /// Records a transient one-shot hook decision.
    func recordTransientDecision(_ decision: ClaudeHookDecision, id: AgentInteractionID) async
    /// Consumes and removes a transient one-shot hook decision.
    func consumeTransientDecision(id: AgentInteractionID) async -> ClaudeHookDecision?
    /// Discards a transient one-shot hook decision.
    func discardTransientDecision(id: AgentInteractionID) async
    /// Records a transient one-shot hook decision for a provider session.
    func recordTransientDecision(_ decision: ClaudeHookDecision, for key: ClaudeTransientDecisionKey) async
    /// Consumes and removes a transient one-shot hook decision for a provider session.
    func consumeTransientDecision(for key: ClaudeTransientDecisionKey) async -> ClaudeHookDecision?
    /// Discards a transient one-shot hook decision for a provider session.
    func discardTransientDecision(for key: ClaudeTransientDecisionKey) async
}

public extension ClaudeTransientDecisionStoring {
    /// Records a transient one-shot hook decision for a provider session.
    func recordTransientDecision(_ decision: ClaudeHookDecision, for key: ClaudeTransientDecisionKey) async {
        await recordTransientDecision(decision, id: key.interactionId)
    }

    /// Consumes and removes a transient one-shot hook decision for a provider session.
    func consumeTransientDecision(for key: ClaudeTransientDecisionKey) async -> ClaudeHookDecision? {
        await consumeTransientDecision(id: key.interactionId)
    }

    /// Discards a transient one-shot hook decision for a provider session.
    func discardTransientDecision(for key: ClaudeTransientDecisionKey) async {
        await discardTransientDecision(id: key.interactionId)
    }
}

/// Store for session and transient Claude approvals.
public actor ClaudeApprovalPolicyStore: ClaudeApprovalPolicyStoring, ClaudeTransientDecisionStoring {
    private var sessionApprovedOperations: Set<ClaudeApprovalOperationKey> = []
    private var sessionApprovalGrants: Set<AgentSessionApprovalGrant> = []
    private var transientDecisions: [ClaudeTransientDecisionKey: ClaudeHookDecision] = [:]

    /// Creates an approval policy store.
    public init() {}

    /// Approves an operation for the rest of the session.
    public func approveForSession(operation: String) {
        sessionApprovedOperations.insert(ClaudeApprovalOperationKey(operation: operation))
    }

    /// Approves an operation input for the rest of the session.
    public func approveForSession(operation: String, input: JSONValue) {
        sessionApprovedOperations.insert(ClaudeApprovalOperationKey(operation: operation, input: input))
    }

    /// Returns whether an operation is approved for the session.
    public func isSessionApproved(operation: String) -> Bool {
        sessionApprovedOperations.contains(ClaudeApprovalOperationKey(operation: operation))
    }

    /// Returns whether an operation input is approved for the session.
    public func isSessionApproved(operation: String, input: JSONValue) -> Bool {
        sessionApprovedOperations.contains(ClaudeApprovalOperationKey(operation: operation, input: input))
            || isSessionApproved(operation: operation)
    }

    /// Records a provider-neutral durable session approval grant.
    public func recordSessionApproval(_ grant: AgentSessionApprovalGrant) -> AgentSessionApprovalRecordResult {
        let inserted = sessionApprovalGrants.insert(grant).inserted
        return AgentSessionApprovalRecordResult(isEffective: true, wasInserted: inserted)
    }

    /// Removes a previously recorded durable session approval grant.
    public func discardSessionApproval(_ grant: AgentSessionApprovalGrant) {
        sessionApprovalGrants.remove(grant)
    }

    /// Returns whether a provider-neutral approval request matches a durable session grant.
    public func allowsSessionApproval(_ request: AgentSessionApprovalRequest) -> Bool {
        request.sessionApprovalGrantCandidates
            .contains { sessionApprovalGrants.contains($0) }
    }

    /// Removes durable session approval grants for a provider session.
    public func removeSessionApprovals(
        providerId: AgentProviderID,
        conversationId: AgentConversationID,
        sessionId: AgentSessionID
    ) {
        sessionApprovalGrants = sessionApprovalGrants.filter {
            $0.providerId != providerId || $0.conversationId != conversationId || $0.sessionId != sessionId
        }
    }

    /// Adds transient one-shot approvals.
    public func approveBatch(_ ids: [AgentInteractionID]) async {
        for id in ids {
            transientDecisions[ClaudeTransientDecisionKey(sessionId: nil, interactionId: id)] = .allow()
        }
    }

    /// Consumes and removes a transient approval.
    public func consumeTransientApproval(id: AgentInteractionID) async -> Bool {
        removeTransientDecision(for: ClaudeTransientDecisionKey(sessionId: nil, interactionId: id))?.approval == .allow
    }

    /// Records a transient one-shot hook decision.
    public func recordTransientDecision(_ decision: ClaudeHookDecision, id: AgentInteractionID) async {
        transientDecisions[ClaudeTransientDecisionKey(sessionId: nil, interactionId: id)] = decision
    }

    /// Consumes and removes a transient one-shot hook decision.
    public func consumeTransientDecision(id: AgentInteractionID) async -> ClaudeHookDecision? {
        removeTransientDecision(for: ClaudeTransientDecisionKey(sessionId: nil, interactionId: id))
    }

    /// Discards a transient one-shot hook decision.
    public func discardTransientDecision(id: AgentInteractionID) async {
        transientDecisions.removeValue(forKey: ClaudeTransientDecisionKey(sessionId: nil, interactionId: id))
    }

    /// Records a transient one-shot hook decision for a provider session.
    public func recordTransientDecision(_ decision: ClaudeHookDecision, for key: ClaudeTransientDecisionKey) async {
        transientDecisions[key] = decision
    }

    /// Consumes and removes a transient one-shot hook decision for a provider session.
    public func consumeTransientDecision(for key: ClaudeTransientDecisionKey) async -> ClaudeHookDecision? {
        removeTransientDecision(for: key)
    }

    /// Discards a transient one-shot hook decision for a provider session.
    public func discardTransientDecision(for key: ClaudeTransientDecisionKey) async {
        transientDecisions.removeValue(forKey: key)
    }

    private func removeTransientDecision(for key: ClaudeTransientDecisionKey) -> ClaudeHookDecision? {
        transientDecisions.removeValue(forKey: key) ?? consumeLegacyTransientDecision(for: key)
    }

    private func consumeLegacyTransientDecision(for key: ClaudeTransientDecisionKey) -> ClaudeHookDecision? {
        guard key.sessionId != nil else {
            return nil
        }
        return transientDecisions.removeValue(forKey: ClaudeTransientDecisionKey(sessionId: nil, interactionId: key.interactionId))
    }
}

private struct ClaudeApprovalOperationKey: Hashable {
    let operation: String
    let input: JSONValue?

    init(operation: String, input: JSONValue? = nil) {
        self.operation = operation
        self.input = input
    }
}

/// Maps HTTP-like hook responses to fail-closed Claude decisions.
public enum ClaudeHookResponseMapper {
    /// Maps a response body to a decision, denying when a 2xx response lacks an explicit allow.
    public static func decision(from response: AgentHookResponse) -> ClaudeApprovalDecision {
        guard (200..<300).contains(response.statusCode), case let .object(body)? = response.body else {
            return .deny
        }
        let permissionDecision = hookSpecificPermissionDecision(from: body) ?? body["decision"]
        if permissionDecision == .string("allow") {
            return .allow
        }
        if permissionDecision == .string("defer") {
            return .deferDecision
        }
        return .deny
    }

    private static func hookSpecificPermissionDecision(from body: [String: JSONValue]) -> JSONValue? {
        guard case let .object(output)? = body["hookSpecificOutput"] else {
            return nil
        }
        return output["permissionDecision"]
    }
}

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

/// Store for session and transient Claude approvals.
public actor ClaudeApprovalPolicyStore {
    private var sessionApprovedOperations: Set<ClaudeApprovalOperationKey> = []
    private var transientApprovals: Set<AgentInteractionID> = []

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

    /// Adds transient one-shot approvals.
    public func approveBatch(_ ids: [AgentInteractionID]) {
        transientApprovals.formUnion(ids)
    }

    /// Consumes and removes a transient approval.
    public func consumeTransientApproval(id: AgentInteractionID) -> Bool {
        transientApprovals.remove(id) != nil
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

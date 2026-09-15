import Foundation

/// Diagnostic information emitted by a harness or runtime.
public struct AgentDiagnosticEvent: Codable, Equatable, Sendable {
    /// Stable machine-readable code for host UI mapping.
    public let code: AgentDiagnosticCode?
    /// Diagnostic severity.
    public let severity: AgentDiagnosticSeverity
    /// Diagnostic message.
    public let message: String
    /// Harness-specific diagnostic fields.
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
/// Raw values retain their original spelling so persisted diagnostics remain readable.
public enum AgentDiagnosticCode: String, Codable, Hashable, Sendable {
    /// Harness stderr output forwarded as a diagnostic.
    case harnessStderr = "providerStderr"
    /// Harness stdout could not be decoded.
    case harnessDecodeFailed = "providerDecodeFailed"
    /// Harness hook approval failed before it could be resolved.
    case hookApprovalFailed
    /// Harness session persistence failed.
    case sessionStoreSaveFailed
    /// Codex App Server process exited unexpectedly.
    case codexAppServerCrash
    /// Codex App Server returned a JSON-RPC error response.
    case codexAppServerJSONRPCError
    /// Codex App Server request timed out.
    case codexAppServerRequestTimeout
    /// Codex App Server request response could not be sent.
    case codexAppServerResponseFailure
    /// Codex App Server shutdown timed out.
    case codexAppServerShutdownTimeout
    /// The runtime could not start implementation after a plan-mode approval.
    case planImplementationStartFailed
    /// The process-scoped host MCP listener stopped after harness launch.
    case hostToolServerUnavailable
    /// The harness rejected the turn because its stored credential must be renewed.
    ///
    /// Hosts should offer a sign-in path rather than presenting this as an ordinary turn failure.
    case harnessAuthenticationRequired = "providerAuthenticationRequired"
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

/// Raw harness output event.
public struct AgentRawOutputEvent: Codable, Equatable, Sendable {
    /// Raw output line or chunk.
    public let text: String
    /// Whether the text was complete at the harness stream boundary.
    public let isComplete: Bool

    /// Creates a raw output event.
    public init(text: String, isComplete: Bool) {
        self.text = text
        self.isComplete = isComplete
    }
}

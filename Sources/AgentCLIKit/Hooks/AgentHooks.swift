import Foundation

/// Provider-neutral hook event accepted from a local hook listener.
public struct AgentHookEvent: Codable, Equatable, Sendable {
    /// Event identifier supplied by the hook listener.
    public let id: String
    /// Provider that emitted the hook.
    public let providerId: AgentProviderID
    /// Hook name or phase.
    public let name: String
    /// Host conversation identifier when known.
    public let conversationId: AgentConversationID?
    /// JSON-compatible hook payload.
    public let payload: JSONValue
    /// Date the hook was accepted.
    public let receivedAt: Date

    /// Creates a hook event.
    public init(
        id: String,
        providerId: AgentProviderID,
        name: String,
        conversationId: AgentConversationID?,
        payload: JSONValue,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.providerId = providerId
        self.name = name
        self.conversationId = conversationId
        self.payload = payload
        self.receivedAt = receivedAt
    }
}

/// Bearer token issued to a provider hook process.
public struct AgentHookToken: Codable, Equatable, Hashable, Sendable {
    /// Opaque token value.
    public let value: String
    /// Expiration date.
    public let expiresAt: Date

    /// Creates a hook token.
    public init(value: String = UUID().uuidString, expiresAt: Date) {
        self.value = value
        self.expiresAt = expiresAt
    }
}

/// Response returned by a local hook listener.
public struct AgentHookResponse: Codable, Equatable, Sendable {
    /// HTTP-like status code.
    public let statusCode: Int
    /// Optional response body.
    public let body: JSONValue?

    /// Creates a hook response.
    public init(statusCode: Int, body: JSONValue? = nil) {
        self.statusCode = statusCode
        self.body = body
    }

    /// Successful hook response that leaves the provider to make its normal decision.
    public static var noDecision: AgentHookResponse {
        AgentHookResponse(statusCode: 200, body: nil)
    }

    /// Successful hook response that explicitly lets the provider continue.
    public static var continueProcessing: AgentHookResponse {
        AgentHookResponse(statusCode: 200, body: .object(["continue": .bool(true)]))
    }
}

/// Token lifecycle service for local provider hook listeners.
public actor AgentHookTokenStore {
    private var tokens: [String: AgentHookToken] = [:]
    private let now: @Sendable () -> Date

    /// Creates a hook token store.
    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    /// Issues and stores a token that expires after the supplied interval.
    public func issue(validFor interval: TimeInterval) -> AgentHookToken {
        let token = AgentHookToken(expiresAt: now().addingTimeInterval(interval))
        tokens[token.value] = token
        return token
    }

    /// Issues and stores a token that remains valid until explicitly invalidated.
    public func issueProcessScoped() -> AgentHookToken {
        let token = AgentHookToken(expiresAt: .distantFuture)
        tokens[token.value] = token
        return token
    }

    /// Returns whether the token exists and has not expired.
    public func validate(_ value: String) -> Bool {
        guard let token = tokens[value], token.expiresAt > now() else {
            return false
        }
        return true
    }

    /// Invalidates a token immediately.
    public func invalidate(_ value: String) {
        tokens[value] = nil
    }

    func token(for value: String) -> AgentHookToken? {
        tokens[value]
    }

    /// Removes all expired tokens.
    public func removeExpired() {
        let currentDate = now()
        tokens = tokens.filter { $0.value.expiresAt > currentDate }
    }
}

/// Minimal hook listener contract that providers can bridge to HTTP or another transport.
public protocol AgentHookListening: Sendable {
    /// Handles a hook event after transport-level token validation succeeds.
    func handle(_ event: AgentHookEvent) async -> AgentHookResponse
}

import Foundation

/// Snapshot of provider context-window usage.
public struct AgentContextWindowSnapshot: Codable, Equatable, Sendable {
    /// Host conversation identifier.
    public let conversationId: AgentConversationID
    /// Provider identifier.
    public let providerId: AgentProviderID
    /// Input tokens currently in context.
    public let usedTokens: Int
    /// Maximum provider context tokens when known.
    public let maximumTokens: Int?
    /// Snapshot date.
    public let measuredAt: Date

    /// Fraction of the context window currently used.
    public var usageFraction: Double? {
        guard let maximumTokens, maximumTokens > 0 else {
            return nil
        }
        return Double(usedTokens) / Double(maximumTokens)
    }

    /// Creates a context-window snapshot.
    public init(
        conversationId: AgentConversationID,
        providerId: AgentProviderID,
        usedTokens: Int,
        maximumTokens: Int?,
        measuredAt: Date = Date()
    ) {
        self.conversationId = conversationId
        self.providerId = providerId
        self.usedTokens = usedTokens
        self.maximumTokens = maximumTokens
        self.measuredAt = measuredAt
    }
}

/// Cache for the latest context-window snapshot per conversation and provider.
public actor AgentContextWindowCache {
    private var snapshots: [ContextKey: AgentContextWindowSnapshot] = [:]

    /// Creates a context-window cache.
    public init() {}

    /// Stores the latest snapshot.
    public func save(_ snapshot: AgentContextWindowSnapshot) {
        snapshots[ContextKey(snapshot.conversationId, snapshot.providerId)] = snapshot
    }

    /// Loads the latest snapshot.
    public func snapshot(conversationId: AgentConversationID, providerId: AgentProviderID) -> AgentContextWindowSnapshot? {
        snapshots[ContextKey(conversationId, providerId)]
    }

    /// Removes the latest snapshot.
    public func remove(conversationId: AgentConversationID, providerId: AgentProviderID) {
        snapshots[ContextKey(conversationId, providerId)] = nil
    }
}

/// Helpers for provider-neutral context handoff prompts.
public enum AgentContextHandoffPrompt {
    /// Builds a prompt asking an agent to summarize state for a fresh session.
    public static func makeSummaryPrompt(task: String, recentTranscript: String, constraints: [String] = []) -> String {
        var sections = [
            "Summarize the current agent session so another agent can continue it.",
            "Task:\n\(task)",
            "Recent transcript:\n\(recentTranscript)"
        ]
        if !constraints.isEmpty {
            sections.append("Constraints:\n\(constraints.map { "- \($0)" }.joined(separator: "\n"))")
        }
        sections.append("Include decisions made, files changed, validation run, and remaining work.")
        return sections.joined(separator: "\n\n")
    }
}

private struct ContextKey: Hashable {
    let conversationId: AgentConversationID
    let providerId: AgentProviderID

    init(_ conversationId: AgentConversationID, _ providerId: AgentProviderID) {
        self.conversationId = conversationId
        self.providerId = providerId
    }
}

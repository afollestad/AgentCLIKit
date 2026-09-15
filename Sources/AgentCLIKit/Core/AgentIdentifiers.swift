import Foundation

/// Stable identifier for an agent harness supported by AgentCLIKit.
public enum AgentHarnessID: String, Codable, Hashable, Sendable, CaseIterable {
    /// Claude Code harness.
    case claude
    /// Codex harness backed by Codex App Server.
    case codex
}

/// Host-defined identifier for an app-level agent conversation.
public struct AgentConversationID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    /// The host application conversation identifier.
    public let rawValue: String

    /// Creates a conversation identifier.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a conversation identifier from a string literal.
    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

/// Harness-defined identifier for a resumable CLI session.
public struct AgentSessionID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    /// The harness session identifier.
    public let rawValue: String

    /// Creates a harness session identifier.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a harness session identifier from a string literal.
    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

/// Identifier for an approval, prompt, or other host-resolved interaction.
public struct AgentInteractionID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    /// The interaction identifier.
    public let rawValue: String

    /// Creates an interaction identifier.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates an interaction identifier from a string literal.
    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

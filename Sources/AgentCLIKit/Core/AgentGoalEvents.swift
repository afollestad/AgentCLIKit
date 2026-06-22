import Foundation

/// Provider-neutral lifecycle status for an active or terminal goal.
public enum AgentGoalStatus: String, Codable, Hashable, Sendable {
    /// Provider is actively pursuing the goal.
    case active
    /// Provider has paused goal pursuit and may be resumed where supported.
    case paused
    /// Provider reported that the goal was achieved.
    case achieved
    /// Provider reported that the goal is blocked.
    case blocked
    /// Provider stopped goal pursuit because a usage or budget limit was reached.
    case usageLimited
    /// Provider reported that the goal was cleared.
    case cleared

    /// Whether this status should be treated as terminal by hosts.
    public var isTerminal: Bool {
        switch self {
        case .active, .paused:
            false
        case .achieved, .blocked, .usageLimited, .cleared:
            true
        }
    }
}

/// Provider-neutral action that can be requested for an active goal.
public enum AgentGoalAction: String, Codable, Hashable, Sendable, CaseIterable {
    /// Pause goal pursuit where the provider supports it.
    case pause
    /// Resume a paused goal where the provider supports it.
    case resume
    /// Delete or clear the active goal where the provider supports it.
    case delete
}

/// Provider-reported goal state for a conversation.
public struct AgentGoalSnapshot: Codable, Equatable, Sendable {
    /// User-visible goal objective.
    public let objective: String
    /// Provider-reported status.
    public let status: AgentGoalStatus
    /// Actions currently supported by this provider/session for the goal.
    public let availableActions: [AgentGoalAction]
    /// Optional elapsed time in seconds.
    public let elapsedSeconds: Int?
    /// Optional turn count reported by the provider.
    public let turnCount: Int?
    /// Optional token count reported by the provider.
    public let tokenCount: Int?
    /// Optional provider-facing reason or detail for the status.
    public let statusReason: String?
    /// Provider-specific metadata for hosts that need richer display or diagnostics.
    public let metadata: [String: JSONValue]

    /// Creates a goal snapshot.
    public init(
        objective: String,
        status: AgentGoalStatus,
        availableActions: [AgentGoalAction] = [],
        elapsedSeconds: Int? = nil,
        turnCount: Int? = nil,
        tokenCount: Int? = nil,
        statusReason: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.objective = objective
        self.status = status
        self.availableActions = availableActions
        self.elapsedSeconds = elapsedSeconds
        self.turnCount = turnCount
        self.tokenCount = tokenCount
        self.statusReason = statusReason
        self.metadata = metadata
    }

    /// Decodes a goal snapshot, defaulting additive fields for older persisted values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.objective = try container.decode(String.self, forKey: .objective)
        self.status = try container.decode(AgentGoalStatus.self, forKey: .status)
        self.availableActions = try container.decodeIfPresent([AgentGoalAction].self, forKey: .availableActions) ?? []
        self.elapsedSeconds = try container.decodeIfPresent(Int.self, forKey: .elapsedSeconds)
        self.turnCount = try container.decodeIfPresent(Int.self, forKey: .turnCount)
        self.tokenCount = try container.decodeIfPresent(Int.self, forKey: .tokenCount)
        self.statusReason = try container.decodeIfPresent(String.self, forKey: .statusReason)
        self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    }
}

/// Provider-neutral goal event emitted by adapters or runtime-owned provider resources.
public struct AgentGoalEvent: Codable, Equatable, Sendable {
    /// Latest provider-reported snapshot. `nil` when the provider confirmed the goal was cleared.
    public let snapshot: AgentGoalSnapshot?
    /// Whether this event represents a provider-confirmed clear/delete.
    public let isCleared: Bool
    /// Last known objective when a provider reports a clear without an active snapshot.
    public let objective: String?
    /// Provider-specific metadata for diagnostics.
    public let metadata: [String: JSONValue]

    /// Creates a goal event.
    public init(
        snapshot: AgentGoalSnapshot?,
        isCleared: Bool = false,
        objective: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.snapshot = snapshot
        self.isCleared = isCleared
        self.objective = objective ?? snapshot?.objective
        self.metadata = metadata
    }

    /// Creates a provider-confirmed clear event.
    public static func cleared(objective: String? = nil, metadata: [String: JSONValue] = [:]) -> AgentGoalEvent {
        AgentGoalEvent(snapshot: nil, isCleared: true, objective: objective, metadata: metadata)
    }

    /// Decodes a goal event, defaulting additive fields for older persisted values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.snapshot = try container.decodeIfPresent(AgentGoalSnapshot.self, forKey: .snapshot)
        self.isCleared = try container.decodeIfPresent(Bool.self, forKey: .isCleared) ?? false
        self.objective = try container.decodeIfPresent(String.self, forKey: .objective) ?? snapshot?.objective
        self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    }
}

/// Metadata keys for goal-mode inputs and events.
public enum AgentGoalMetadata {
    /// Marks an initial provider input that should use provider-native goal-start transport.
    public static let isInitialGoalTransport = "agent_goal_initial_transport"
    /// Stores the user-visible goal objective.
    public static let objective = "agent_goal_objective"
}

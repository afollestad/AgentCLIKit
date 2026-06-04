import Foundation

/// Provider turn or thread activity state used for runtime work detection.
public struct AgentActivityEvent: Codable, Equatable, Sendable {
    /// Activity state.
    public let state: AgentActivityState
    /// Provider turn identifier when known.
    public let turnId: String?
    /// Provider-specific activity metadata.
    public let metadata: [String: JSONValue]

    /// Creates an activity event.
    public init(state: AgentActivityState, turnId: String? = nil, metadata: [String: JSONValue] = [:]) {
        self.state = state
        self.turnId = turnId
        self.metadata = metadata
    }

    /// Decodes activity events, defaulting metadata for older persisted values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.state = try container.decode(AgentActivityState.self, forKey: .state)
        self.turnId = try container.decodeIfPresent(String.self, forKey: .turnId)
        self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    }
}

/// Provider activity state.
public enum AgentActivityState: String, Codable, Hashable, Sendable {
    /// Provider is actively working on a turn.
    case active
    /// Provider is not actively working on a turn.
    case idle
}

/// Provider context compaction lifecycle event.
public struct AgentContextCompactionEvent: Codable, Equatable, Sendable {
    /// Stable provider or runtime-defined compaction identifier.
    public let id: String
    /// Compaction lifecycle phase.
    public let phase: AgentContextCompactionPhase
    /// Provider trigger, such as `manual` or `auto`, when known.
    public let trigger: String?
    /// Provider-supplied completion summary when known.
    public let summary: String?
    /// Provider-supplied failure detail when compaction fails.
    public let errorMessage: String?
    /// Token count before compaction when known.
    public let preTokens: Int?
    /// Token count after compaction when known.
    public let postTokens: Int?
    /// Compaction duration in milliseconds when known.
    public let durationMs: Int?
    /// Provider-specific compaction metadata.
    public let metadata: [String: JSONValue]

    /// Creates a context compaction event.
    public init(
        id: String,
        phase: AgentContextCompactionPhase,
        trigger: String? = nil,
        summary: String? = nil,
        errorMessage: String? = nil,
        preTokens: Int? = nil,
        postTokens: Int? = nil,
        durationMs: Int? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.phase = phase
        self.trigger = trigger
        self.summary = summary
        self.errorMessage = errorMessage
        self.preTokens = preTokens
        self.postTokens = postTokens
        self.durationMs = durationMs
        self.metadata = metadata
    }

    /// Decodes context compaction events, defaulting metadata for older persisted values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.phase = try container.decode(AgentContextCompactionPhase.self, forKey: .phase)
        self.trigger = try container.decodeIfPresent(String.self, forKey: .trigger)
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary)
        self.errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        self.preTokens = try container.decodeIfPresent(Int.self, forKey: .preTokens)
        self.postTokens = try container.decodeIfPresent(Int.self, forKey: .postTokens)
        self.durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    }
}

/// Context compaction lifecycle phase.
public enum AgentContextCompactionPhase: String, Codable, Hashable, Sendable {
    /// Context compaction started.
    case started
    /// Context compaction completed successfully.
    case completed
    /// Context compaction failed.
    case failed

    /// Whether this phase finishes a compaction lifecycle.
    public var isTerminal: Bool {
        switch self {
        case .started:
            false
        case .completed, .failed:
            true
        }
    }
}

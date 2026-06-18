import Foundation

/// Provider-neutral lifecycle phase for a spawned sub-agent.
public enum AgentSubAgentPhase: String, Codable, Hashable, Sendable {
    /// Sub-agent work started.
    case started
    /// Sub-agent work reported progress.
    case progress
    /// Sub-agent work reached a terminal state.
    case terminal
}

/// Provider-neutral sub-agent lifecycle event.
public struct AgentSubAgentEvent: Codable, Equatable, Sendable {
    /// Provider-defined sub-agent or spawning tool identifier.
    public let id: String
    /// Sub-agent lifecycle phase.
    public let phase: AgentSubAgentPhase
    /// Human-readable sub-agent description when known.
    public let description: String?
    /// Prompt given to the sub-agent when known.
    public let prompt: String?
    /// Provider-defined sub-agent type when known.
    public let agentType: String?
    /// Original provider input used to spawn or describe the sub-agent.
    public let input: JSONValue?
    /// Last tool name reported by the provider for this sub-agent.
    public let lastToolName: String?
    /// Provider status when known.
    public let status: String?
    /// Terminal result text when known.
    public let result: String?
    /// Number of tool uses reported by the sub-agent.
    public let toolUses: Int?
    /// Total tokens reported by the sub-agent.
    public let totalTokens: Int?
    /// Sub-agent duration in milliseconds.
    public let durationMs: Int?
    /// Parent provider tool-use identifier when known.
    public let parentToolUseId: String?
    /// Caller agent identifier when reported by the provider.
    public let callerAgent: String?
    /// Parent provider session identifier when known.
    public let parentSessionId: String?
    /// Child provider session identifiers when known.
    public let childSessionIds: [String]
    /// Provider-specific sub-agent metadata.
    public let metadata: [String: JSONValue]

    /// Creates a sub-agent lifecycle event.
    public init(
        id: String,
        phase: AgentSubAgentPhase,
        description: String? = nil,
        prompt: String? = nil,
        agentType: String? = nil,
        input: JSONValue? = nil,
        lastToolName: String? = nil,
        status: String? = nil,
        result: String? = nil,
        toolUses: Int? = nil,
        totalTokens: Int? = nil,
        durationMs: Int? = nil,
        parentToolUseId: String? = nil,
        callerAgent: String? = nil,
        parentSessionId: String? = nil,
        childSessionIds: [String] = [],
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.phase = phase
        self.description = description
        self.prompt = prompt
        self.agentType = agentType
        self.input = input
        self.lastToolName = lastToolName
        self.status = status
        self.result = result
        self.toolUses = toolUses
        self.totalTokens = totalTokens
        self.durationMs = durationMs
        self.parentToolUseId = parentToolUseId
        self.callerAgent = callerAgent
        self.parentSessionId = parentSessionId
        self.childSessionIds = childSessionIds
        self.metadata = metadata
    }

    /// Decodes sub-agent events, defaulting additive fields for persisted events from older versions.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.phase = try container.decode(AgentSubAgentPhase.self, forKey: .phase)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        self.agentType = try container.decodeIfPresent(String.self, forKey: .agentType)
        self.input = try container.decodeIfPresent(JSONValue.self, forKey: .input)
        self.lastToolName = try container.decodeIfPresent(String.self, forKey: .lastToolName)
        self.status = try container.decodeIfPresent(String.self, forKey: .status)
        self.result = try container.decodeIfPresent(String.self, forKey: .result)
        self.toolUses = try container.decodeIfPresent(Int.self, forKey: .toolUses)
        self.totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
        self.durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        self.parentToolUseId = try container.decodeIfPresent(String.self, forKey: .parentToolUseId)
        self.callerAgent = try container.decodeIfPresent(String.self, forKey: .callerAgent)
        self.parentSessionId = try container.decodeIfPresent(String.self, forKey: .parentSessionId)
        self.childSessionIds = try container.decodeIfPresent([String].self, forKey: .childSessionIds) ?? []
        self.metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    }
}

extension AgentSubAgentPhase {
    var isTerminal: Bool {
        self == .terminal
    }
}

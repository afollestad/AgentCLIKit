import Foundation

/// Usage information for a provider response or model invocation.
public struct AgentUsageEvent: Codable, Equatable, Sendable {
    /// Provider model name when known.
    public let model: String?
    /// Input tokens consumed.
    public let inputTokens: Int?
    /// Output tokens produced.
    public let outputTokens: Int?
    /// Cache-read input tokens consumed.
    public let cacheReadInputTokens: Int?
    /// Cache-creation input tokens consumed.
    public let cacheCreationInputTokens: Int?
    /// Total tokens reported by the provider.
    public let totalTokens: Int?
    /// Number of tool uses reported by the provider.
    public let toolUses: Int?
    /// Provider run duration in milliseconds.
    public let durationMs: Int?
    /// Provider-reported cost in USD, when available.
    public let costUSD: Double?
    /// Model context window size when known.
    public let contextWindow: Int?
    /// Provider stop reason when known.
    public let stopReason: String?
    /// Whether this usage event represents a terminal result for the turn.
    public let isTerminal: Bool
    /// Whether the provider marked this result as an error.
    public let isError: Bool
    /// Permission denials summarized by the provider.
    public let permissionDenials: [AgentPermissionDenialSummary]
    /// Additional provider-specific usage values.
    public let metadata: [String: JSONValue]

    /// Creates a usage event.
    public init(
        model: String?,
        inputTokens: Int?,
        outputTokens: Int?,
        cacheReadInputTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil,
        totalTokens: Int? = nil,
        toolUses: Int? = nil,
        durationMs: Int? = nil,
        costUSD: Double? = nil,
        contextWindow: Int? = nil,
        stopReason: String? = nil,
        isTerminal: Bool = false,
        isError: Bool = false,
        permissionDenials: [AgentPermissionDenialSummary] = [],
        metadata: [String: JSONValue] = [:]
    ) {
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.totalTokens = totalTokens
        self.toolUses = toolUses
        self.durationMs = durationMs
        self.costUSD = costUSD
        self.contextWindow = contextWindow
        self.stopReason = stopReason
        self.isTerminal = isTerminal
        self.isError = isError
        self.permissionDenials = permissionDenials
        self.metadata = metadata
    }

    /// Decodes usage events, defaulting new typed fields for persisted events from older versions.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
        let stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason) ?? metadata.stringValue("stop_reason")
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
        self.outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
        self.cacheReadInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens)
            ?? metadata.intValue("cache_read_input_tokens")
        self.cacheCreationInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens)
            ?? metadata.intValue("cache_creation_input_tokens")
        self.totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? metadata.intValue("total_tokens")
        self.toolUses = try container.decodeIfPresent(Int.self, forKey: .toolUses) ?? metadata.intValue("tool_uses")
        self.durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs) ?? metadata.intValue("duration_ms")
        self.costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD) ?? metadata.doubleValue("total_cost_usd")
        self.contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow) ?? metadata.intValue("context_window")
        self.stopReason = stopReason
        self.isTerminal = try container.decodeIfPresent(Bool.self, forKey: .isTerminal) ?? (stopReason != nil && stopReason != "usage_update")
        self.isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? metadata.boolValue("is_error") ?? false
        self.permissionDenials = try container.decodeIfPresent([AgentPermissionDenialSummary].self, forKey: .permissionDenials) ?? []
        self.metadata = metadata
    }
}

private extension [String: JSONValue] {
    func stringValue(_ key: String) -> String? {
        guard case let .string(value)? = self[key] else {
            return nil
        }
        return value
    }

    func intValue(_ key: String) -> Int? {
        guard case let .number(value)? = self[key] else {
            return nil
        }
        return Int(value)
    }

    func boolValue(_ key: String) -> Bool? {
        guard case let .bool(value)? = self[key] else {
            return nil
        }
        return value
    }

    func doubleValue(_ key: String) -> Double? {
        guard case let .number(value)? = self[key] else {
            return nil
        }
        return value
    }
}

/// Provider-reported permission denial.
public struct AgentPermissionDenialSummary: Codable, Equatable, Sendable {
    /// Provider tool-use identifier when known.
    public let toolUseId: String?
    /// Tool name when known.
    public let toolName: String?
    /// Provider denial reason.
    public let reason: String?
    /// Provider-specific denial metadata.
    public let metadata: [String: JSONValue]

    /// Creates a permission-denial summary.
    public init(toolUseId: String?, toolName: String?, reason: String?, metadata: [String: JSONValue] = [:]) {
        self.toolUseId = toolUseId
        self.toolName = toolName
        self.reason = reason
        self.metadata = metadata
    }
}

/// Provider permission mode state.
public struct AgentPermissionModeEvent: Codable, Equatable, Sendable {
    /// Provider permission mode value.
    public let mode: String
    /// Provider-specific permission-mode metadata.
    public let metadata: [String: JSONValue]

    /// Creates a permission-mode event.
    public init(mode: String, metadata: [String: JSONValue] = [:]) {
        self.mode = mode
        self.metadata = metadata
    }
}

/// Provider task or sub-agent activity.
public struct AgentTaskEvent: Codable, Equatable, Sendable {
    /// Provider-defined task identifier.
    public let id: String
    /// Task lifecycle phase.
    public let phase: AgentTaskPhase
    /// Human-readable task description when known.
    public let description: String?
    /// Provider task type when known.
    public let taskType: String?
    /// Last tool name reported by the task.
    public let lastToolName: String?
    /// Number of tool uses reported by the task.
    public let toolUses: Int?
    /// Total tokens reported by the task.
    public let totalTokens: Int?
    /// Task duration in milliseconds.
    public let durationMs: Int?
    /// Provider status when known.
    public let status: String?
    /// Provider-specific task metadata.
    public let metadata: [String: JSONValue]

    /// Creates a task event.
    public init(
        id: String,
        phase: AgentTaskPhase,
        description: String? = nil,
        taskType: String? = nil,
        lastToolName: String? = nil,
        toolUses: Int? = nil,
        totalTokens: Int? = nil,
        durationMs: Int? = nil,
        status: String? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.phase = phase
        self.description = description
        self.taskType = taskType
        self.lastToolName = lastToolName
        self.toolUses = toolUses
        self.totalTokens = totalTokens
        self.durationMs = durationMs
        self.status = status
        self.metadata = metadata
    }
}

/// Task lifecycle phase.
public enum AgentTaskPhase: String, Codable, Hashable, Sendable {
    /// Task started.
    case started
    /// Task reported progress.
    case progress
    /// Task emitted a notification.
    case notification
    /// Task completed.
    case completed
}

/// Provider session continuity outcome for a launch.
public struct AgentSessionContinuityEvent: Codable, Equatable, Sendable {
    /// Session continuity kind.
    public let continuity: AgentSessionContinuity
    /// Provider session identifier when known.
    public let providerSessionId: AgentSessionID?
    /// Human-readable detail.
    public let message: String?

    /// Creates a session-continuity event.
    public init(continuity: AgentSessionContinuity, providerSessionId: AgentSessionID?, message: String? = nil) {
        self.continuity = continuity
        self.providerSessionId = providerSessionId
        self.message = message
    }
}

/// Provider session continuity kind.
public enum AgentSessionContinuity: String, Codable, Hashable, Sendable {
    /// A new provider session is starting.
    case fresh
    /// An existing provider session is being resumed.
    case resumed
    /// The requested provider session was unavailable and the launch restarted with that session ID.
    case restartedFresh
}

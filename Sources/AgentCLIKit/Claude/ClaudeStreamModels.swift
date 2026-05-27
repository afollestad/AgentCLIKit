import Foundation

struct ClaudeStreamEnvelope: Decodable {
    let type: String
    let subtype: String?
    let uuid: String?
    let sessionId: String?
    let parentToolUseId: String?
    let model: String?
    let message: ClaudeStreamMessage?
    let event: ClaudeStreamEvent?
    let attachment: ClaudeAttachment?
    let toolUseResult: ClaudeToolUseResult?
    let result: String?
    let usage: ClaudeUsage?
    let isError: Bool?
    let stopReason: String?
    let durationMs: Int?
    let totalCostUSD: Double?
    let modelUsage: [String: ClaudeModelUsage]?
    let toolUseId: String?
    let description: String?
    let taskType: String?
    let lastToolName: String?
    let status: String?
    let deferredToolUse: ClaudeDeferredToolUse?
    let permissionMode: String?
    let permissionDenials: [ClaudePermissionDenial]
    let rateLimitInfo: ClaudeRateLimitInfo?

    var parentMetadata: [String: JSONValue] {
        guard let parentToolUseId else {
            return [:]
        }
        return ["parent_tool_use_id": .string(parentToolUseId)]
    }

    var resultMetadata: [String: JSONValue] {
        var metadata = usage?.metadata ?? [:]
        if let stopReason {
            metadata["stop_reason"] = .string(stopReason)
        }
        if let durationMs {
            metadata["duration_ms"] = .number(Double(durationMs))
        }
        if let totalCostUSD {
            metadata["total_cost_usd"] = .number(totalCostUSD)
        }
        if let isError {
            metadata["is_error"] = .bool(isError)
        }
        return metadata
    }

    var rawTypeDescription: String {
        subtype.map { "\(type):\($0)" } ?? type
    }

    func matchedModelUsage() -> (modelId: String, contextWindow: Int?)? {
        guard let modelUsage, !modelUsage.isEmpty else {
            return nil
        }
        if let usage,
           let match = modelUsage.first(where: { _, value in value.matches(usage) }) {
            return (modelId: match.key, contextWindow: match.value.contextWindow)
        }
        let fallback = modelUsage.max { lhs, rhs in
            lhs.value.tokenTotal < rhs.value.tokenTotal
        }
        return fallback.map { (modelId: $0.key, contextWindow: $0.value.contextWindow) }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case subtype
        case uuid
        case sessionId = "session_id"
        case sessionIdCamel = "sessionId"
        case parentToolUseId = "parent_tool_use_id"
        case model
        case message
        case event
        case attachment
        case toolUseResult = "tool_use_result"
        case result
        case usage
        case isError = "is_error"
        case stopReason = "stop_reason"
        case durationMs = "duration_ms"
        case totalCostUSD = "total_cost_usd"
        case modelUsage
        case toolUseId = "tool_use_id"
        case description
        case taskType = "task_type"
        case lastToolName = "last_tool_name"
        case status
        case deferredToolUse = "deferred_tool_use"
        case permissionMode
        case permissionDenials = "permission_denials"
        case rateLimitInfo = "rate_limit_info"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(String.self, forKey: .type)
        self.subtype = container.decodeLenientIfPresent(String.self, forKey: .subtype)
        self.uuid = container.decodeLenientIfPresent(String.self, forKey: .uuid)
        self.sessionId = container.decodeLenientIfPresent(String.self, forKey: .sessionId)
            ?? container.decodeLenientIfPresent(String.self, forKey: .sessionIdCamel)
        self.parentToolUseId = container.decodeLenientIfPresent(String.self, forKey: .parentToolUseId)
        self.model = container.decodeLenientIfPresent(String.self, forKey: .model)
        self.message = container.decodeLenientIfPresent(ClaudeStreamMessage.self, forKey: .message)
        self.event = container.decodeLenientIfPresent(ClaudeStreamEvent.self, forKey: .event)
        self.attachment = container.decodeLenientIfPresent(ClaudeAttachment.self, forKey: .attachment)
        self.toolUseResult = container.decodeLenientIfPresent(ClaudeToolUseResult.self, forKey: .toolUseResult)
        self.result = container.decodeLenientIfPresent(String.self, forKey: .result)
        self.usage = container.decodeLenientIfPresent(ClaudeUsage.self, forKey: .usage)
        self.isError = container.decodeLenientIfPresent(Bool.self, forKey: .isError)
        self.stopReason = container.decodeLenientIfPresent(String.self, forKey: .stopReason)
        self.durationMs = container.decodeLenientIntIfPresent(forKey: .durationMs)
        self.totalCostUSD = container.decodeLenientDoubleIfPresent(forKey: .totalCostUSD)
        self.modelUsage = container.decodeLenientIfPresent([String: ClaudeModelUsage].self, forKey: .modelUsage)
        self.toolUseId = container.decodeLenientIfPresent(String.self, forKey: .toolUseId)
        self.description = container.decodeLenientIfPresent(String.self, forKey: .description)
        self.taskType = container.decodeLenientIfPresent(String.self, forKey: .taskType)
        self.lastToolName = container.decodeLenientIfPresent(String.self, forKey: .lastToolName)
        self.status = container.decodeLenientIfPresent(String.self, forKey: .status)
        self.deferredToolUse = container.decodeLenientIfPresent(ClaudeDeferredToolUse.self, forKey: .deferredToolUse)
        self.permissionMode = container.decodeLenientIfPresent(String.self, forKey: .permissionMode)
        self.permissionDenials = container.decodeLenientIfPresent([ClaudePermissionDenial].self, forKey: .permissionDenials) ?? []
        self.rateLimitInfo = container.decodeLenientIfPresent(ClaudeRateLimitInfo.self, forKey: .rateLimitInfo)
    }
}

struct ClaudeStreamMessage: Decodable {
    let role: String?
    let content: [ClaudeContent]
    let usage: ClaudeUsage?

    var agentRole: AgentMessageRole {
        switch role {
        case "user":
            .user
        case "system":
            .system
        case "tool":
            .tool
        default:
            .assistant
        }
    }
}

struct ClaudeContent: Decodable {
    let type: String
    let text: String?
    let thinking: String?
    let content: String?
    let id: String?
    let name: String?
    let input: JSONValue?
    let caller: ClaudeToolCaller?
    let toolUseId: String?
    let isError: Bool?

    var textContent: String? {
        text ?? content
    }

    var callerMetadata: [String: JSONValue] {
        caller?.metadata ?? [:]
    }

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case thinking
        case content
        case id
        case name
        case input
        case caller
        case toolUseId = "tool_use_id"
        case isError = "is_error"
    }
}

struct ClaudeStreamEvent: Decodable {
    let type: String
    let delta: ClaudeStreamDelta?
}

struct ClaudeStreamDelta: Decodable {
    let type: String
    let text: String?
}

struct ClaudeToolCaller: Decodable {
    let type: String?
    let agent: String?

    var metadata: [String: JSONValue] {
        guard type == "agent", let agent, !agent.isEmpty else {
            return [:]
        }
        return ["caller_agent": .string(agent)]
    }
}

struct ClaudeToolUseResult: Decodable {
    let stdout: String?
    let stderr: String?
    let interrupted: Bool?
    let isImage: Bool?
    let noOutputExpected: Bool?

    var metadata: [String: JSONValue] {
        var metadata: [String: JSONValue] = [:]
        if let stderr {
            metadata["stderr"] = .string(stderr)
        }
        if let interrupted {
            metadata["interrupted"] = .bool(interrupted)
        }
        if let isImage {
            metadata["is_image"] = .bool(isImage)
        }
        if let noOutputExpected {
            metadata["no_output_expected"] = .bool(noOutputExpected)
        }
        return metadata
    }
}

struct ClaudeUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?
    let toolUses: Int?
    let totalTokens: Int?
    let durationMs: Int?

    var metadata: [String: JSONValue] {
        var metadata: [String: JSONValue] = [:]
        if let cacheReadInputTokens {
            metadata["cache_read_input_tokens"] = .number(Double(cacheReadInputTokens))
        }
        if let cacheCreationInputTokens {
            metadata["cache_creation_input_tokens"] = .number(Double(cacheCreationInputTokens))
        }
        return metadata
    }

    var taskMetadata: [String: JSONValue] {
        var metadata: [String: JSONValue] = [:]
        if let toolUses {
            metadata["tool_uses"] = .number(Double(toolUses))
        }
        if let totalTokens {
            metadata["total_tokens"] = .number(Double(totalTokens))
        }
        if let durationMs {
            metadata["duration_ms"] = .number(Double(durationMs))
        }
        return metadata
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case toolUses = "tool_uses"
        case totalTokens = "total_tokens"
        case durationMs = "duration_ms"
    }
}

struct ClaudeRateLimitInfo: Decodable {
    let status: String
    let resetDate: Date?
    let limitType: String?
    let utilization: Double?
    let overageStatus: String?
    let overageResetDate: Date?
    let overageDisabledReason: String?

    var metadata: [String: JSONValue] {
        var metadata: [String: JSONValue] = ["status": .string(status)]
        if let resetDate {
            metadata["resets_at"] = .number(resetDate.timeIntervalSince1970)
        }
        if let limitType {
            metadata["rate_limit_type"] = .string(limitType)
        }
        if let utilization {
            metadata["utilization"] = .number(utilization)
        }
        if let overageStatus {
            metadata["overage_status"] = .string(overageStatus)
        }
        if let overageResetDate {
            metadata["overage_resets_at"] = .number(overageResetDate.timeIntervalSince1970)
        }
        if let overageDisabledReason {
            metadata["overage_disabled_reason"] = .string(overageDisabledReason)
        }
        return metadata
    }

    enum CodingKeys: String, CodingKey {
        case status
        case resetsAt
        case resetsAtSnake = "resets_at"
        case rateLimitType
        case rateLimitTypeSnake = "rate_limit_type"
        case utilization
        case overageStatus
        case overageStatusSnake = "overage_status"
        case overageResetsAt
        case overageResetsAtSnake = "overage_resets_at"
        case overageDisabledReason
        case overageDisabledReasonSnake = "overage_disabled_reason"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.status = container.decodeLenientIfPresent(String.self, forKey: .status) ?? "unknown"
        self.resetDate = Self.decodeDate(from: container, keys: [.resetsAt, .resetsAtSnake])
        self.limitType = container.decodeLenientIfPresent(String.self, forKey: .rateLimitType)
            ?? container.decodeLenientIfPresent(String.self, forKey: .rateLimitTypeSnake)
        self.utilization = container.decodeLenientIfPresent(Double.self, forKey: .utilization)
        self.overageStatus = container.decodeLenientIfPresent(String.self, forKey: .overageStatus)
            ?? container.decodeLenientIfPresent(String.self, forKey: .overageStatusSnake)
        self.overageResetDate = Self.decodeDate(from: container, keys: [.overageResetsAt, .overageResetsAtSnake])
        self.overageDisabledReason = container.decodeLenientIfPresent(String.self, forKey: .overageDisabledReason)
            ?? container.decodeLenientIfPresent(String.self, forKey: .overageDisabledReasonSnake)
    }

    private static func decodeDate(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Date? {
        for key in keys {
            if let seconds = container.decodeLenientIfPresent(Double.self, forKey: key) {
                return Date(timeIntervalSince1970: normalizedUnixSeconds(seconds))
            }
            if let seconds = container.decodeLenientIfPresent(Int.self, forKey: key) {
                return Date(timeIntervalSince1970: normalizedUnixSeconds(TimeInterval(seconds)))
            }
        }
        return nil
    }

    private static func normalizedUnixSeconds(_ value: TimeInterval) -> TimeInterval {
        abs(value) > 10_000_000_000 ? value / 1_000 : value
    }
}

struct ClaudePermissionDenial: Decodable {
    let toolUseId: String?
    let toolName: String?
    let reason: String?

    var summary: AgentPermissionDenialSummary {
        AgentPermissionDenialSummary(toolUseId: toolUseId, toolName: toolName, reason: reason)
    }

    enum CodingKeys: String, CodingKey {
        case toolUseId = "tool_use_id"
        case toolUseIdCamel = "toolUseId"
        case toolName = "tool_name"
        case toolNameCamel = "toolName"
        case reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.toolUseId = try container.decodeIfPresent(String.self, forKey: .toolUseId)
            ?? container.decodeIfPresent(String.self, forKey: .toolUseIdCamel)
        self.toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
            ?? container.decodeIfPresent(String.self, forKey: .toolNameCamel)
        self.reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }
}

private extension KeyedDecodingContainer {
    func decodeLenientIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        do {
            return try decodeIfPresent(type, forKey: key)
        } catch {
            return nil
        }
    }

    func decodeLenientIntIfPresent(forKey key: Key) -> Int? {
        if let value = decodeLenientIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = decodeLenientIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        return decodeLenientIfPresent(String.self, forKey: key).flatMap(Int.init)
    }

    func decodeLenientDoubleIfPresent(forKey key: Key) -> Double? {
        if let value = decodeLenientIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = decodeLenientIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        return decodeLenientIfPresent(String.self, forKey: key).flatMap(Double.init)
    }
}

struct ClaudeDeferredToolUse: Decodable {
    let id: String
    let name: String
    let input: JSONValue?
}

struct ClaudeModelUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?
    let contextWindow: Int?

    var tokenTotal: Int {
        (inputTokens ?? 0) + (outputTokens ?? 0) + (cacheReadInputTokens ?? 0) + (cacheCreationInputTokens ?? 0)
    }

    func matches(_ usage: ClaudeUsage) -> Bool {
        (inputTokens ?? 0) == (usage.inputTokens ?? 0)
            && (outputTokens ?? 0) == (usage.outputTokens ?? 0)
            && (cacheReadInputTokens ?? 0) == (usage.cacheReadInputTokens ?? 0)
            && (cacheCreationInputTokens ?? 0) == (usage.cacheCreationInputTokens ?? 0)
    }
}

import Foundation

struct ClaudeStreamEnvelope: Decodable {
    let type: String
    let subtype: String?
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(String.self, forKey: .type)
        self.subtype = try container.decodeIfPresent(String.self, forKey: .subtype)
        self.sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
            ?? container.decodeIfPresent(String.self, forKey: .sessionIdCamel)
        self.parentToolUseId = try container.decodeIfPresent(String.self, forKey: .parentToolUseId)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.message = try container.decodeIfPresent(ClaudeStreamMessage.self, forKey: .message)
        self.event = try container.decodeIfPresent(ClaudeStreamEvent.self, forKey: .event)
        self.attachment = try container.decodeIfPresent(ClaudeAttachment.self, forKey: .attachment)
        self.toolUseResult = try container.decodeIfPresent(ClaudeToolUseResult.self, forKey: .toolUseResult)
        self.result = try container.decodeIfPresent(String.self, forKey: .result)
        self.usage = try container.decodeIfPresent(ClaudeUsage.self, forKey: .usage)
        self.isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
        self.stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)
        self.durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        self.totalCostUSD = try container.decodeIfPresent(Double.self, forKey: .totalCostUSD)
        self.modelUsage = try container.decodeIfPresent([String: ClaudeModelUsage].self, forKey: .modelUsage)
        self.toolUseId = try container.decodeIfPresent(String.self, forKey: .toolUseId)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.taskType = try container.decodeIfPresent(String.self, forKey: .taskType)
        self.lastToolName = try container.decodeIfPresent(String.self, forKey: .lastToolName)
        self.status = try container.decodeIfPresent(String.self, forKey: .status)
        self.deferredToolUse = try container.decodeIfPresent(ClaudeDeferredToolUse.self, forKey: .deferredToolUse)
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

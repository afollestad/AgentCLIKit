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
    let origin: ClaudeStreamOrigin?
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
    let summary: String?
    let taskType: String?
    let lastToolName: String?
    let status: String?
    let outputFile: String?
    let deferredToolUse: ClaudeDeferredToolUse?
    let permissionMode: String?
    let permissionDenials: [ClaudePermissionDenial]
    let rateLimitInfo: ClaudeRateLimitInfo?
    let operation: String?
    let content: String?

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
        case origin
        case attachment
        case toolUseResult = "tool_use_result"
        case toolUseResultCamel = "toolUseResult"
        case result
        case usage
        case isError = "is_error"
        case stopReason = "stop_reason"
        case durationMs = "duration_ms"
        case totalCostUSD = "total_cost_usd"
        case modelUsage
        case toolUseId = "tool_use_id"
        case description
        case summary
        case taskType = "task_type"
        case lastToolName = "last_tool_name"
        case status
        case outputFile = "output_file"
        case deferredToolUse = "deferred_tool_use"
        case permissionMode
        case permissionDenials = "permission_denials"
        case rateLimitInfo = "rate_limit_info"
        case operation
        case content
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
        self.origin = container.decodeLenientIfPresent(ClaudeStreamOrigin.self, forKey: .origin)
        self.attachment = container.decodeLenientIfPresent(ClaudeAttachment.self, forKey: .attachment)
        self.toolUseResult = container.decodeLenientIfPresent(ClaudeToolUseResult.self, forKey: .toolUseResult)
            ?? container.decodeLenientIfPresent(ClaudeToolUseResult.self, forKey: .toolUseResultCamel)
        self.result = container.decodeLenientIfPresent(String.self, forKey: .result)
        self.usage = container.decodeLenientIfPresent(ClaudeUsage.self, forKey: .usage)
        self.isError = container.decodeLenientIfPresent(Bool.self, forKey: .isError)
        self.stopReason = container.decodeLenientIfPresent(String.self, forKey: .stopReason)
        self.durationMs = container.decodeLenientIntIfPresent(forKey: .durationMs)
        self.totalCostUSD = container.decodeLenientDoubleIfPresent(forKey: .totalCostUSD)
        self.modelUsage = container.decodeLenientIfPresent([String: ClaudeModelUsage].self, forKey: .modelUsage)
        self.toolUseId = container.decodeLenientIfPresent(String.self, forKey: .toolUseId)
        self.description = container.decodeLenientIfPresent(String.self, forKey: .description)
        self.summary = container.decodeLenientIfPresent(String.self, forKey: .summary)
        self.taskType = container.decodeLenientIfPresent(String.self, forKey: .taskType)
        self.lastToolName = container.decodeLenientIfPresent(String.self, forKey: .lastToolName)
        self.status = container.decodeLenientIfPresent(String.self, forKey: .status)
        self.outputFile = container.decodeLenientIfPresent(String.self, forKey: .outputFile)
        self.deferredToolUse = container.decodeLenientIfPresent(ClaudeDeferredToolUse.self, forKey: .deferredToolUse)
        self.permissionMode = container.decodeLenientIfPresent(String.self, forKey: .permissionMode)
        self.permissionDenials = container.decodeLenientIfPresent([ClaudePermissionDenial].self, forKey: .permissionDenials) ?? []
        self.rateLimitInfo = container.decodeLenientIfPresent(ClaudeRateLimitInfo.self, forKey: .rateLimitInfo)
        self.operation = container.decodeLenientIfPresent(String.self, forKey: .operation)
        self.content = container.decodeLenientIfPresent(String.self, forKey: .content)
    }
}

struct ClaudeStreamMessage: Decodable {
    let role: String?
    let content: [ClaudeContent]
    let rawContent: String?
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

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case usage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = container.decodeLenientIfPresent(String.self, forKey: .role)
        self.content = container.decodeLenientIfPresent([ClaudeContent].self, forKey: .content) ?? []
        self.rawContent = container.decodeLenientIfPresent(String.self, forKey: .content)
        self.usage = container.decodeLenientIfPresent(ClaudeUsage.self, forKey: .usage)
    }
}

struct ClaudeStreamOrigin: Decodable {
    let kind: String?
}

struct ClaudeContent: Decodable {
    let type: String
    let text: String?
    let thinking: String?
    let content: ClaudeTextContent?
    let id: String?
    let name: String?
    let input: JSONValue?
    let caller: ClaudeToolCaller?
    let toolUseId: String?
    let isError: Bool?

    var textContent: String? {
        text ?? content?.stringText
    }

    var textContentWithoutContinuationMetadata: String? {
        text ?? content?.text(excludingContinuationMetadata: true)
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
    let content: ClaudeTextContent?
    let task: JSONValue?
    let tasks: JSONValue?
    let todos: JSONValue?

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
        if let task {
            metadata["task"] = task
        }
        if let tasks {
            metadata["tasks"] = tasks
        }
        if let todos {
            metadata["todos"] = todos
        }
        return metadata
    }
}

struct ClaudeTextContent: Decodable {
    private let value: Value

    var text: String? {
        text()
    }

    var stringText: String? {
        guard case .string(let string) = value else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : string
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = .string(string)
        } else {
            value = .blocks(try container.decode([Block].self))
        }
    }

    func text(excludingContinuationMetadata: Bool = false) -> String? {
        let text: String
        switch value {
        case .string(let string):
            text = string
        case .blocks(let blocks):
            text = blocks.compactMap { block -> String? in
                guard block.type == nil || block.type == "text",
                      let text = block.text else {
                    return nil
                }
                if excludingContinuationMetadata && Self.isContinuationMetadata(text) {
                    return nil
                }
                return text
            }.joined(separator: "\n")
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    private static func isContinuationMetadata(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("agentId:") && trimmed.contains("<usage>")
    }

    private enum Value {
        case string(String)
        case blocks([Block])
    }

    private struct Block: Decodable {
        let type: String?
        let text: String?
    }
}

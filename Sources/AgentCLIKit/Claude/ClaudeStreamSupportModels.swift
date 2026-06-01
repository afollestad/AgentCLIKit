import Foundation

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

extension KeyedDecodingContainer {
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

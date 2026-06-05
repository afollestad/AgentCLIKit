import Foundation

extension CodexAppServerNotificationDecoder {
    func decodeThreadTokenUsageUpdated(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        guard let params = notification.params?.codexObjectValue,
              let threadId = params["threadId"]?.codexStringValue,
              let turnId = params["turnId"]?.codexStringValue,
              let tokenUsage = params["tokenUsage"]?.codexObjectValue,
              let total = tokenUsage["total"]?.codexObjectValue else {
            return []
        }

        let last = tokenUsage["last"]?.codexObjectValue
        let contextWindow = tokenUsage["modelContextWindow"]?.codexIntValue
        let current = last ?? total
        let inputTokens = current["inputTokens"]?.codexIntValue
        let outputTokens = current["outputTokens"]?.codexIntValue
        let cacheReadInputTokens = current["cachedInputTokens"]?.codexIntValue
        let totalTokens = current["totalTokens"]?.codexIntValue
        var metadata = codexNotificationMetadata(
            method: notification.method,
            threadId: threadId,
            turnId: turnId,
            values: [
                "stop_reason": .string(AgentUsageEvent.interimUsageStopReason),
                "input_tokens": inputTokens.map(JSONValue.numberValue),
                "output_tokens": outputTokens.map(JSONValue.numberValue),
                "cache_read_input_tokens": cacheReadInputTokens.map(JSONValue.numberValue),
                "reasoning_output_tokens": current["reasoningOutputTokens"],
                "total_tokens": totalTokens.map(JSONValue.numberValue),
                "context_window": contextWindow.map(JSONValue.numberValue),
                "codex_last_token_usage": last.map(JSONValue.object)
            ]
        )
        metadata["codex_total_token_usage"] = .object(total)

        return [codexRuntimeEvent(.usage(AgentUsageEvent(
            model: nil,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadInputTokens: cacheReadInputTokens,
            totalTokens: totalTokens,
            contextWindow: contextWindow,
            stopReason: AgentUsageEvent.interimUsageStopReason,
            isTerminal: false,
            metadata: metadata
        )))]
    }

    func decodeAccountRateLimitsUpdated(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        guard let params = notification.params?.codexObjectValue,
              let rateLimits = params["rateLimits"]?.codexObjectValue else {
            return []
        }

        let primary = rateLimits["primary"]?.codexObjectValue
        let secondary = rateLimits["secondary"]?.codexObjectValue
        let usedPercent = [primary, secondary].compactMap { $0?["usedPercent"]?.codexIntValue }.max()
        let resetAt = primary?["resetsAt"]?.codexIntValue ?? secondary?["resetsAt"]?.codexIntValue
        let reachedType = rateLimits["rateLimitReachedType"]?.codexStringValue
        let status: AgentRateLimitStatus
        if reachedType != nil {
            status = .rejected
        } else if (usedPercent ?? 0) >= 80 {
            status = .allowedWarning
        } else {
            status = .allowed
        }

        let metadata = codexCompacted([
            "codex_method": .string(notification.method),
            "codex_rate_limits": .object(rateLimits),
            "limit_id": rateLimits["limitId"],
            "limit_name": rateLimits["limitName"],
            "plan_type": rateLimits["planType"],
            "rate_limit_reached_type": rateLimits["rateLimitReachedType"],
            "used_percent": usedPercent.map(JSONValue.numberValue),
            "resets_at": resetAt.map(JSONValue.numberValue)
        ])
        return [codexRuntimeEvent(.rateLimit(AgentRateLimitEvent(
            status: status,
            resetDate: resetAt.map(Self.dateFromProviderTimestamp),
            limitType: rateLimits["limitId"]?.codexStringValue ?? rateLimits["limitName"]?.codexStringValue,
            utilization: usedPercent.map { Double($0) / 100.0 },
            metadata: metadata
        )))]
    }

    func decodeTurnPlanUpdated(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        guard let params = notification.params?.codexObjectValue,
              let threadId = params["threadId"]?.codexStringValue,
              let turnId = params["turnId"]?.codexStringValue,
              let plan = params["plan"]?.codexArrayValue else {
            return []
        }

        let todos = plan.enumerated().compactMap { index, value -> JSONValue? in
            guard let step = value.codexObjectValue,
                  let stepText = step["step"]?.codexStringValue else {
                return nil
            }
            let status = normalizedTaskStatus(step["status"]?.codexStringValue)
            return .object(codexCompacted([
                "id": .string("codex-plan-\(turnId)-\(index)"),
                "subject": .string(stepText),
                "status": status.map(JSONValue.string)
            ]))
        }
        let currentStep = plan.first { value in
            value.codexObjectValue?["status"]?.codexStringValue == "inProgress"
        }?.codexObjectValue?["step"]?.codexStringValue
        let explanation = params["explanation"]?.codexStringValue
        let metadata = codexNotificationMetadata(
            method: notification.method,
            threadId: threadId,
            turnId: turnId,
            values: [
                "codex_plan": .array(plan),
                "todos": todos.isEmpty ? nil : .array(todos),
                "explanation": explanation.map(JSONValue.string)
            ]
        )
        return [codexRuntimeEvent(.task(AgentTaskEvent(
            id: "codex-plan-\(turnId)",
            phase: .progress,
            description: explanation ?? currentStep ?? "Plan updated",
            taskType: "plan",
            status: "updated",
            metadata: metadata
        )))]
    }

    func decodePlanDelta(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        guard let params = notification.params?.codexObjectValue,
              let threadId = params["threadId"]?.codexStringValue,
              let turnId = params["turnId"]?.codexStringValue,
              let itemId = params["itemId"]?.codexStringValue,
              let delta = params["delta"]?.codexStringValue,
              !delta.isEmpty else {
            return []
        }

        let metadata = codexNotificationMetadata(
            method: notification.method,
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            values: ["codex_plan_delta": .string(delta)]
        )
        return [codexRuntimeEvent(.task(AgentTaskEvent(
            id: itemId,
            phase: .progress,
            description: delta,
            taskType: "plan",
            status: "streaming",
            metadata: metadata
        )))]
    }

    func decodeThreadCompacted(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        guard let params = notification.params?.codexObjectValue,
              let threadId = params["threadId"]?.codexStringValue,
              let turnId = params["turnId"]?.codexStringValue else {
            return []
        }

        let metadata = codexNotificationMetadata(method: notification.method, threadId: threadId, turnId: turnId)
        return [codexRuntimeEvent(.contextCompaction(AgentContextCompactionEvent(
            id: "codex-context-compaction-\(turnId)",
            phase: .completed,
            metadata: metadata
        )))]
    }

    func decodeModelRerouted(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        guard let params = notification.params?.codexObjectValue,
              let threadId = params["threadId"]?.codexStringValue,
              let turnId = params["turnId"]?.codexStringValue,
              let fromModel = params["fromModel"]?.codexStringValue,
              let toModel = params["toModel"]?.codexStringValue else {
            return []
        }

        let reason = params["reason"]?.codexStringValue
        let metadata = codexNotificationMetadata(
            method: notification.method,
            threadId: threadId,
            turnId: turnId,
            values: [
                "from_model": .string(fromModel),
                "to_model": .string(toModel),
                "reason": reason.map(JSONValue.string)
            ]
        )
        return [codexRuntimeEvent(.diagnostic(AgentDiagnosticEvent(
            severity: .info,
            message: "Codex rerouted the model for this turn.",
            metadata: metadata
        )))]
    }

    func decodeModelVerification(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        guard let params = notification.params?.codexObjectValue,
              let threadId = params["threadId"]?.codexStringValue,
              let turnId = params["turnId"]?.codexStringValue,
              let verifications = params["verifications"]?.codexArrayValue else {
            return []
        }

        let metadata = codexNotificationMetadata(
            method: notification.method,
            threadId: threadId,
            turnId: turnId,
            values: ["verifications": .array(verifications)]
        )
        return [codexRuntimeEvent(.diagnostic(AgentDiagnosticEvent(
            severity: .info,
            message: "Codex verified model access requirements.",
            metadata: metadata
        )))]
    }

    private func normalizedTaskStatus(_ status: String?) -> String? {
        switch status {
        case "inProgress":
            "inProgress"
        case "completed":
            "completed"
        case "pending":
            "pending"
        default:
            status
        }
    }

    private func codexRuntimeEvent(_ event: AgentEvent) -> AgentProviderRuntimeEvent {
        AgentProviderRuntimeEvent(event: event, source: .runtime)
    }

    private func codexNotificationMetadata(
        method: String,
        threadId: String,
        turnId: String? = nil,
        itemId: String? = nil,
        values: [String: JSONValue?] = [:]
    ) -> [String: JSONValue] {
        var metadata: [String: JSONValue] = [
            "codex_method": .string(method),
            "codex_thread_id": .string(threadId)
        ]
        if let turnId {
            metadata["codex_turn_id"] = .string(turnId)
        }
        if let itemId {
            metadata["codex_item_id"] = .string(itemId)
        }
        metadata.merge(codexCompacted(values)) { _, new in new }
        return metadata
    }

    private func codexCompacted(_ values: [String: JSONValue?]) -> [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value -> (String, JSONValue)? in
            guard let value, value != .null else {
                return nil
            }
            return (key, value)
        })
    }

    private static func dateFromProviderTimestamp(_ timestamp: Int) -> Date {
        if timestamp > 10_000_000_000 {
            return Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
}

private extension JSONValue {
    static func numberValue(_ value: Int) -> JSONValue {
        .number(Double(value))
    }

    var codexArrayValue: [JSONValue]? {
        guard case let .array(value) = self else {
            return nil
        }
        return value
    }

    var codexIntValue: Int? {
        guard case let .number(value) = self else {
            return nil
        }
        return Int(value)
    }

    var codexObjectValue: [String: JSONValue]? {
        guard case let .object(value) = self else {
            return nil
        }
        return value
    }

    var codexStringValue: String? {
        guard case let .string(value) = self, !value.isEmpty else {
            return nil
        }
        return value
    }
}

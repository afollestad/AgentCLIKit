import Foundation

/// Decodes Claude Code stream JSON stdout into provider-neutral events.
public struct ClaudeStreamDecoder: Sendable {
    /// Creates a Claude stream decoder.
    public init() {}

    /// Decodes one stream JSON line.
    public func decodeLine(_ line: String) throws -> [AgentEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }
        let data = Data(trimmed.utf8)
        let envelope = try JSONDecoder().decode(ClaudeStreamEnvelope.self, from: data)
        return try events(from: envelope)
    }

    private func events(from envelope: ClaudeStreamEnvelope) throws -> [AgentEvent] {
        switch envelope.type {
        case "system":
            return systemEvents(from: envelope)
        case "assistant", "user":
            return messageEvents(from: envelope)
        case "stream_event":
            return streamEvents(from: envelope)
        case "result":
            return resultEvents(from: envelope)
        case "rate_limit_event":
            return rateLimitEvents(from: envelope)
        case "hook":
            return hookEvents(from: envelope)
        case "attachment":
            return attachmentEvents(from: envelope)
        case "queue-operation":
            return queueOperationEvents(from: envelope)
        default:
            return [.rawOutput(AgentRawOutputEvent(text: envelope.rawTypeDescription, isComplete: true))]
        }
    }

    private func queueOperationEvents(from envelope: ClaudeStreamEnvelope) -> [AgentEvent] {
        guard envelope.operation == "enqueue",
              let content = envelope.content,
              content.contains("<task-notification>") else {
            return []
        }
        return taskNotificationEvents(from: content)
    }

    private func systemEvents(from envelope: ClaudeStreamEnvelope) -> [AgentEvent] {
        var events: [AgentEvent] = []
        let metadata = systemMetadata(from: envelope)
        if let permissionMode = envelope.permissionMode {
            events.append(.permissionMode(AgentPermissionModeEvent(mode: permissionMode, metadata: metadata)))
            events.append(.collaborationMode(AgentCollaborationModeEvent(
                mode: permissionMode == "plan" ? .plan : .default,
                metadata: metadata
            )))
        }
        if let compactionEvent = contextCompactionEvent(from: envelope, metadata: metadata) {
            events.append(compactionEvent)
        } else if let taskEvent = taskEvent(from: envelope, metadata: metadata) {
            events.append(taskEvent)
        } else {
            events.append(.diagnostic(AgentDiagnosticEvent(severity: .info, message: envelope.subtype ?? "system", metadata: metadata)))
        }
        return events
    }

    private func messageEvents(from envelope: ClaudeStreamEnvelope) -> [AgentEvent] {
        guard let message = envelope.message else {
            return []
        }
        if let rawContent = message.rawContent,
           envelope.origin?.kind == "task-notification" || rawContent.contains("<task-notification>") {
            return taskNotificationEvents(from: rawContent)
        }
        var events: [AgentEvent] = []
        for content in message.content {
            events.append(contentsOf: contentEvents(
                from: content,
                role: message.agentRole,
                metadata: envelope.parentMetadata,
                toolUseResult: envelope.toolUseResult
            ))
        }
        if let usage = message.usage {
            events.append(usageEvent(
                usage,
                model: envelope.model,
                extraMetadata: [:],
                defaultStopReason: AgentUsageEvent.interimUsageStopReason
            ))
        }
        return events
    }

    func taskNotificationEvents(from rawContent: String) -> [AgentEvent] {
        guard let notification = ClaudeTaskNotificationParser.parse(rawContent) else {
            return []
        }
        var metadata: [String: JSONValue] = ["tool_use_id": .string(notification.toolUseId)]
        if let taskId = notification.taskId {
            metadata["task_id"] = .string(taskId)
        }
        if let summary = notification.summary {
            metadata["summary"] = .string(summary)
        }
        if let result = notification.result {
            metadata["result"] = .string(result)
        }
        if let outputFile = notification.outputFile {
            metadata["output_file"] = .string(outputFile)
        }
        if let status = notification.status {
            metadata["status"] = .string(status)
        }
        if let totalTokens = notification.totalTokens {
            metadata["total_tokens"] = .number(Double(totalTokens))
        }
        if let toolUses = notification.toolUses {
            metadata["tool_uses"] = .number(Double(toolUses))
        }
        if let durationMs = notification.durationMs {
            metadata["duration_ms"] = .number(Double(durationMs))
        }

        return [.task(AgentTaskEvent(
            id: notification.toolUseId,
            phase: .notification,
            description: notification.summary,
            toolUses: notification.toolUses,
            totalTokens: notification.totalTokens,
            durationMs: notification.durationMs,
            status: notification.status,
            metadata: metadata
        ))]
    }

    private func contentEvents(
        from content: ClaudeContent,
        role: AgentMessageRole,
        metadata: [String: JSONValue],
        toolUseResult: ClaudeToolUseResult?
    ) -> [AgentEvent] {
        switch content.type {
        case "thinking":
            guard let thinking = content.thinking, !thinking.isEmpty else {
                return []
            }
            return [.reasoning(AgentReasoningEvent(text: thinking, metadata: metadata))]
        case "text":
            return textEvents(from: content, role: role, metadata: metadata)
        case "tool_use":
            return toolUseEvents(from: content, metadata: metadata)
        case "tool_result":
            return toolResultEvents(from: content, metadata: metadata, toolUseResult: toolUseResult)
        default:
            return [.rawOutput(AgentRawOutputEvent(text: content.type, isComplete: true))]
        }
    }

    private func textEvents(
        from content: ClaudeContent,
        role: AgentMessageRole,
        metadata: [String: JSONValue]
    ) -> [AgentEvent] {
        guard let text = content.text.map(ClaudeCaveatStripper.strip), !text.isEmpty else {
            return []
        }
        if role == .user, ClaudeInterruptionMarker.isUserInterruption(text) {
            return [.lifecycle(AgentLifecycleEvent(state: .cancelled, message: "Interrupted"))]
        }
        // Claude reports local command output as user text; hosts render it as provider output, not as a user-authored prompt.
        let eventRole: AgentMessageRole = role == .user ? .assistant : role
        return [.message(AgentMessageEvent(role: eventRole, text: text, metadata: metadata))]
    }

    private func toolUseEvents(from content: ClaudeContent, metadata: [String: JSONValue]) -> [AgentEvent] {
        guard let id = content.id, !id.isEmpty, let name = content.name, !name.isEmpty else {
            return [.diagnostic(AgentDiagnosticEvent(
                severity: .error,
                message: "Malformed Claude event: missing tool_use id or name in assistant block"
            ))]
        }
        return [.toolCall(AgentToolCallEvent(
            id: id,
            name: name,
            input: content.input ?? .object([:]),
            metadata: metadata.merging(content.callerMetadata) { _, new in new }
        ))]
    }

    private func toolResultEvents(
        from content: ClaudeContent,
        metadata: [String: JSONValue],
        toolUseResult: ClaudeToolUseResult?
    ) -> [AgentEvent] {
        guard let toolUseId = content.toolUseId, !toolUseId.isEmpty else {
            return [.diagnostic(AgentDiagnosticEvent(
                severity: .error,
                message: "Malformed Claude event: missing tool_use_id in tool_result"
            ))]
        }
        return [.toolResult(AgentToolResultEvent(
            id: toolUseId,
            isError: content.isError ?? false,
            content: content.textContent
                ?? toolUseResult?.content?.text
                ?? content.textContentWithoutContinuationMetadata
                ?? toolUseResult?.stdout
                ?? "",
            metadata: metadata.merging(toolUseResult?.metadata ?? [:]) { _, new in new }
        ))]
    }

    private func streamEvents(from envelope: ClaudeStreamEnvelope) -> [AgentEvent] {
        guard envelope.event?.type == "content_block_delta",
              envelope.event?.delta?.type == "text_delta",
              let text = envelope.event?.delta?.text,
              !text.isEmpty else {
            return []
        }
        return [.messageDelta(AgentMessageDeltaEvent(role: .assistant, text: text, metadata: envelope.parentMetadata))]
    }

    private func resultEvents(from envelope: ClaudeStreamEnvelope) -> [AgentEvent] {
        var events: [AgentEvent] = []
        let matchedModelUsage = envelope.matchedModelUsage()
        if let deferredInteraction = deferredToolInteraction(from: envelope) {
            events.append(deferredInteraction)
        }
        if envelope.subtype == "error" || envelope.isError == true {
            events.append(.diagnostic(AgentDiagnosticEvent(severity: .error, message: envelope.result ?? "Claude result error")))
        }
        if let usage = envelope.usage {
            var metadata = envelope.resultMetadata
            if envelope.subtype == "error", metadata["is_error"] == nil {
                metadata["is_error"] = .bool(true)
            }
            if let contextWindow = matchedModelUsage?.contextWindow {
                metadata["context_window"] = .number(Double(contextWindow))
            }
            events.append(usageEvent(
                usage,
                model: matchedModelUsage?.modelId ?? envelope.model,
                extraMetadata: metadata,
                permissionDenials: envelope.permissionDenials.map(\.summary)
            ))
        } else if !envelope.resultMetadata.isEmpty {
            var metadata = envelope.resultMetadata
            if envelope.subtype == "error", metadata["is_error"] == nil {
                metadata["is_error"] = .bool(true)
            }
            events.append(.usage(AgentUsageEvent(
                model: matchedModelUsage?.modelId ?? envelope.model,
                inputTokens: nil,
                outputTokens: nil,
                durationMs: envelope.durationMs,
                costUSD: envelope.totalCostUSD,
                stopReason: envelope.stopReason,
                isTerminal: true,
                isError: envelope.isError == true || envelope.subtype == "error",
                permissionDenials: envelope.permissionDenials.map(\.summary),
                metadata: metadata
            )))
        }
        if envelope.subtype == "interrupted" {
            events.append(.lifecycle(AgentLifecycleEvent(state: .cancelled, message: "Claude reported interruption.")))
        }
        return events
    }

    private func hookEvents(from envelope: ClaudeStreamEnvelope) -> [AgentEvent] {
        if envelope.isError == true {
            return [.diagnostic(AgentDiagnosticEvent(severity: .error, message: envelope.result ?? "Claude hook failed"))]
        }
        return [.diagnostic(AgentDiagnosticEvent(severity: .info, message: envelope.subtype ?? "hook"))]
    }

    private func rateLimitEvents(from envelope: ClaudeStreamEnvelope) -> [AgentEvent] {
        guard let rateLimitInfo = envelope.rateLimitInfo else {
            return [.diagnostic(AgentDiagnosticEvent(
                severity: .warning,
                message: "Claude rate-limit event was missing rate_limit_info."
            ))]
        }
        var metadata = rateLimitInfo.metadata
        if let uuid = envelope.uuid {
            metadata["uuid"] = .string(uuid)
        }
        if let sessionId = envelope.sessionId {
            metadata["session_id"] = .string(sessionId)
        }
        return [.rateLimit(AgentRateLimitEvent(
            status: AgentRateLimitStatus(rawValue: rateLimitInfo.status),
            resetDate: rateLimitInfo.resetDate,
            limitType: rateLimitInfo.limitType,
            utilization: rateLimitInfo.utilization,
            overageStatus: rateLimitInfo.overageStatus.map(AgentRateLimitStatus.init(rawValue:)),
            overageResetDate: rateLimitInfo.overageResetDate,
            overageDisabledReason: rateLimitInfo.overageDisabledReason,
            metadata: metadata
        ))]
    }

    private func usageEvent(
        _ usage: ClaudeUsage,
        model: String?,
        extraMetadata: [String: JSONValue],
        permissionDenials: [AgentPermissionDenialSummary] = [],
        defaultStopReason: String? = nil
    ) -> AgentEvent {
        var metadata = usage.metadata
        metadata.merge(extraMetadata) { _, new in new }
        let stopReason = stringValue(metadata["stop_reason"]) ?? defaultStopReason
        if let defaultStopReason, metadata["stop_reason"] == nil {
            metadata["stop_reason"] = .string(defaultStopReason)
        }
        let durationMs = intValue(metadata["duration_ms"]) ?? usage.durationMs
        let costUSD = doubleValue(metadata["total_cost_usd"])
        let contextWindow = intValue(metadata["context_window"])
        return .usage(AgentUsageEvent(
            model: model,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheReadInputTokens: usage.cacheReadInputTokens,
            cacheCreationInputTokens: usage.cacheCreationInputTokens,
            totalTokens: usage.totalTokens,
            toolUses: usage.toolUses,
            durationMs: durationMs,
            costUSD: costUSD,
            contextWindow: contextWindow,
            stopReason: stopReason,
            isTerminal: stopReason != nil && stopReason != AgentUsageEvent.interimUsageStopReason,
            isError: boolValue(metadata["is_error"]) ?? false,
            permissionDenials: permissionDenials,
            metadata: metadata
        ))
    }

    private func taskEvent(from envelope: ClaudeStreamEnvelope, metadata: [String: JSONValue]) -> AgentEvent? {
        guard let subtype = envelope.subtype,
              let phase = AgentTaskPhase(claudeSubtype: subtype),
              let id = envelope.toolUseId,
              !id.isEmpty else {
            return nil
        }
        return .task(AgentTaskEvent(
            id: id,
            phase: phase,
            description: envelope.description ?? envelope.summary,
            taskType: envelope.taskType,
            lastToolName: envelope.lastToolName,
            toolUses: envelope.usage?.toolUses,
            totalTokens: envelope.usage?.totalTokens,
            durationMs: envelope.usage?.durationMs,
            status: envelope.status,
            metadata: metadata
        ))
    }

    private func deferredToolInteraction(from envelope: ClaudeStreamEnvelope) -> AgentEvent? {
        guard envelope.stopReason == "tool_deferred",
              let deferredToolUse = envelope.deferredToolUse,
              !deferredToolUse.id.isEmpty,
              !deferredToolUse.name.isEmpty else {
            return nil
        }
        var metadata: [String: JSONValue] = [
            "tool_name": .string(deferredToolUse.name),
            "tool_input": deferredToolUse.input ?? .object([:])
        ]
        if let sessionId = envelope.sessionId {
            metadata["session_id"] = .string(sessionId)
        }
        return .interaction(AgentInteractionEvent(
            id: AgentInteractionID(rawValue: deferredToolUse.id),
            kind: Self.interactionKind(forToolName: deferredToolUse.name),
            prompt: deferredToolUse.name,
            metadata: metadata
        ))
    }
}

extension ClaudeStreamDecoder {
    static func interactionKind(forToolName toolName: String) -> AgentInteractionKind {
        switch toolName {
        case "AskUserQuestion":
            .prompt
        case "ExitPlanMode":
            .planModeExit
        default:
            .approval
        }
    }
}

private extension AgentTaskPhase {
    init?(claudeSubtype: String) {
        switch claudeSubtype {
        case "task_started":
            self = .started
        case "task_progress":
            self = .progress
        case "task_notification":
            self = .notification
        case "task_completed":
            self = .completed
        default:
            return nil
        }
    }
}

private func stringValue(_ value: JSONValue?) -> String? {
    guard case let .string(string)? = value else {
        return nil
    }
    return string
}

private func intValue(_ value: JSONValue?) -> Int? {
    guard case let .number(number)? = value else {
        return nil
    }
    return Int(number)
}

private func doubleValue(_ value: JSONValue?) -> Double? {
    guard case let .number(number)? = value else {
        return nil
    }
    return number
}

private func boolValue(_ value: JSONValue?) -> Bool? {
    guard case let .bool(bool)? = value else {
        return nil
    }
    return bool
}

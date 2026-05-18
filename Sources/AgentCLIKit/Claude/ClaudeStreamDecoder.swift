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
        case "hook":
            return hookEvents(from: envelope)
        case "attachment":
            return attachmentEvents(from: envelope)
        default:
            return [.rawOutput(AgentRawOutputEvent(text: envelope.rawTypeDescription, isComplete: true))]
        }
    }

    private func systemEvents(from envelope: ClaudeStreamEnvelope) -> [AgentEvent] {
        var metadata: [String: JSONValue] = [:]
        if let sessionId = envelope.sessionId {
            metadata["session_id"] = .string(sessionId)
        }
        if let model = envelope.model {
            metadata["model"] = .string(model)
        }
        if let toolUseId = envelope.toolUseId {
            metadata["tool_use_id"] = .string(toolUseId)
        }
        if let description = envelope.description {
            metadata["description"] = .string(description)
        }
        if let taskType = envelope.taskType {
            metadata["task_type"] = .string(taskType)
        }
        if let lastToolName = envelope.lastToolName {
            metadata["last_tool_name"] = .string(lastToolName)
        }
        if let status = envelope.status {
            metadata["status"] = .string(status)
        }
        metadata.merge(envelope.usage?.taskMetadata ?? [:]) { _, new in new }
        return [.diagnostic(AgentDiagnosticEvent(severity: .info, message: envelope.subtype ?? "system", metadata: metadata))]
    }

    private func messageEvents(from envelope: ClaudeStreamEnvelope) -> [AgentEvent] {
        guard let message = envelope.message else {
            return []
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
            events.append(usageEvent(usage, model: envelope.model, extraMetadata: [:]))
        }
        return events
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
            content: content.textContent ?? toolUseResult?.stdout ?? "",
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
        if let result = envelope.result.map(ClaudeCaveatStripper.strip), !result.isEmpty {
            events.append(.message(AgentMessageEvent(role: .assistant, text: result)))
        }
        if let usage = envelope.usage {
            var metadata = envelope.resultMetadata
            if let contextWindow = matchedModelUsage?.contextWindow {
                metadata["context_window"] = .number(Double(contextWindow))
            }
            events.append(usageEvent(usage, model: matchedModelUsage?.modelId ?? envelope.model, extraMetadata: metadata))
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

    private func usageEvent(_ usage: ClaudeUsage, model: String?, extraMetadata: [String: JSONValue]) -> AgentEvent {
        var metadata = usage.metadata
        metadata.merge(extraMetadata) { _, new in new }
        return .usage(AgentUsageEvent(
            model: model,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
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
            kind: .approval,
            prompt: deferredToolUse.name,
            metadata: metadata
        ))
    }
}

/// Removes Claude caveat prefixes that should not be persisted as assistant content.
public enum ClaudeCaveatStripper {
    /// Returns text without a leading caveat line.
    public static func strip(_ text: String) -> String {
        let text = stripLocalCommandCaveat(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first.lowercased().hasPrefix("caveat:") else {
            return text
        }
        return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripLocalCommandCaveat(from text: String) -> String {
        let startTag = "<local-command-caveat>"
        let endTag = "</local-command-caveat>"
        var stripped = text
        guard let startRange = stripped.range(of: startTag),
              let endRange = stripped.range(of: endTag, range: startRange.upperBound..<stripped.endIndex) else {
            return stripped
        }
        stripped.removeSubrange(endRange)
        stripped.removeSubrange(startRange)
        return stripped
    }
}

private enum ClaudeInterruptionMarker {
    private static let userInterruptionMarkers = [
        "[Request interrupted by user]",
        "[Request interrupted by user for tool use]"
    ]

    static func isUserInterruption(_ text: String) -> Bool {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return userInterruptionMarkers.contains {
            normalizedText.caseInsensitiveCompare($0) == .orderedSame
        }
    }
}

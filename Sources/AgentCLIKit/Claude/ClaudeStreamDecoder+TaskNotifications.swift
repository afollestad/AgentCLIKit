import Foundation

/// Decoding for Claude's `<task-notification>` payload, which reports a finished sub-agent. It arrives
/// on two unrelated envelope types — a queued `queue-operation` and an ordinary message — so both
/// entry points funnel through one translation.
extension ClaudeStreamDecoder {
    func queueOperationEvents(from envelope: ClaudeStreamEnvelope) -> [AgentEvent] {
        guard envelope.operation == "enqueue",
              let content = envelope.content,
              content.contains("<task-notification>") else {
            return []
        }
        return taskNotificationEvents(from: content, delivery: AgentBackgroundTaskMetadata.enqueuedDelivery)
    }

    func taskNotificationEvents(from rawContent: String, delivery: String) -> [AgentEvent] {
        guard let notification = ClaudeTaskNotificationParser.parse(rawContent) else {
            return []
        }
        var metadata: [String: JSONValue] = [
            "tool_use_id": .string(notification.toolUseId),
            AgentBackgroundTaskMetadata.delivery: .string(delivery)
        ]
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

        return [.subAgent(AgentSubAgentEvent(
            id: notification.toolUseId,
            phase: .terminal,
            description: notification.summary,
            status: notification.status,
            result: notification.result,
            toolUses: notification.toolUses,
            totalTokens: notification.totalTokens,
            durationMs: notification.durationMs,
            metadata: metadata
        ))]
    }
}

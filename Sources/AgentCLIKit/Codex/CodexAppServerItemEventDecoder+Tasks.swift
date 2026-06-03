import Foundation

extension CodexAppServerItemEventDecoder {
    func collabAgentTask(_ payload: ItemPayload, phase: AgentTaskPhase) -> AgentTaskEvent {
        let tool = payload.item["tool"]?.codexStringValue
        let status = itemStatus(payload.item)
        let receiverThreadIds = payload.item["receiverThreadIds"]?.codexArrayValue ?? []
        let agentsStates = payload.item["agentsStates"]?.codexObjectValue
        let metadata = toolMetadata(payload, values: [
            "codex_collab_tool": tool.map(JSONValue.string),
            "sender_thread_id": payload.item["senderThreadId"],
            "receiver_thread_ids": receiverThreadIds.isEmpty ? nil : .array(receiverThreadIds),
            "agents_states": agentsStates.map(JSONValue.object),
            "model": payload.item["model"],
            "reasoning_effort": payload.item["reasoningEffort"],
            "prompt": payload.item["prompt"]
        ])
        return AgentTaskEvent(
            id: payload.id,
            phase: phase == .completed ? phaseForCompletedStatus(status) : phase,
            description: collabDescription(tool: tool, receivers: receiverThreadIds, prompt: payload.item["prompt"]?.codexStringValue),
            taskType: "collabAgentToolCall",
            lastToolName: tool,
            status: status,
            metadata: metadata
        )
    }

    func contextCompactionTask(_ payload: ItemPayload, phase: AgentTaskPhase) -> AgentTaskEvent {
        AgentTaskEvent(
            id: payload.id,
            phase: phase,
            description: phase == .completed ? "Context compacted" : "Compacting context",
            taskType: "contextCompaction",
            status: itemStatus(payload.item),
            metadata: payload.metadata
        )
    }

    private func phaseForCompletedStatus(_ status: String?) -> AgentTaskPhase {
        switch status {
        case "inProgress":
            .progress
        default:
            .completed
        }
    }

    private func collabDescription(tool: String?, receivers: [JSONValue], prompt: String?) -> String {
        if let prompt, !prompt.isEmpty {
            return prompt
        }
        if let tool, !receivers.isEmpty {
            let receiverList = receivers.compactMap(\.codexStringValue).joined(separator: ", ")
            if !receiverList.isEmpty {
                return "\(tool) \(receiverList)"
            }
        }
        return tool ?? "Collaboration agent activity"
    }
}

private extension JSONValue {
    var codexArrayValue: [JSONValue]? {
        guard case let .array(value) = self else {
            return nil
        }
        return value
    }

    var codexObjectValue: [String: JSONValue]? {
        guard case let .object(value) = self else {
            return nil
        }
        return value
    }

    var codexStringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }
}

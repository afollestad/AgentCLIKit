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

    func contextCompactionEvent(_ payload: ItemPayload, phase: AgentContextCompactionPhase) -> AgentContextCompactionEvent {
        let status = itemStatus(payload.item)
        let resolvedPhase: AgentContextCompactionPhase = status == "failed" ? .failed : phase
        let turnId = payload.metadata.stringValue("codex_turn_id")
        let error = payload.item["error"]?.codexObjectValue?["message"]?.codexStringValue
        return AgentContextCompactionEvent(
            id: "codex-context-compaction-\(turnId ?? payload.id)",
            phase: resolvedPhase,
            trigger: payload.item["trigger"]?.codexStringValue,
            summary: payload.item["summary"]?.codexStringValue,
            errorMessage: error,
            preTokens: payload.item["preTokens"]?.codexIntValue ?? payload.item["pre_tokens"]?.codexIntValue,
            postTokens: payload.item["postTokens"]?.codexIntValue ?? payload.item["post_tokens"]?.codexIntValue,
            durationMs: payload.item["durationMs"]?.codexIntValue ?? payload.item["duration_ms"]?.codexIntValue,
            metadata: toolMetadata(payload, values: [
                "codex_status": status.map(JSONValue.string)
            ])
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

    var codexIntValue: Int? {
        guard case let .number(value) = self else {
            return nil
        }
        return Int(value)
    }

    var codexStringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }
}

private extension [String: JSONValue] {
    func stringValue(_ key: String) -> String? {
        guard case let .string(value)? = self[key], !value.isEmpty else {
            return nil
        }
        return value
    }
}

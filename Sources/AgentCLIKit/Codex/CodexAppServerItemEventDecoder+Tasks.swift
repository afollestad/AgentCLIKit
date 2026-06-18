import Foundation

extension CodexAppServerItemEventDecoder {
    func collabAgentSubAgent(_ payload: ItemPayload, phase: AgentSubAgentPhase) -> AgentSubAgentEvent? {
        guard let tool = payload.item["tool"]?.codexStringValue,
              tool.normalizedCollabToolName == "spawnagent" else {
            return nil
        }
        let status = itemStatus(payload.item)
        let receiverThreadIds = payload.item["receiverThreadIds"]?.codexArrayValue ?? []
        let agentsStates = payload.item["agentsStates"]?.codexObjectValue
        let prompt = payload.item["prompt"]?.codexStringValue
        let metadata = toolMetadata(payload, values: [
            "codex_collab_tool": .string(tool),
            "sender_thread_id": payload.item["senderThreadId"],
            "receiver_thread_ids": receiverThreadIds.isEmpty ? nil : .array(receiverThreadIds),
            "agents_states": agentsStates.map(JSONValue.object),
            "model": payload.item["model"],
            "reasoning_effort": payload.item["reasoningEffort"],
            "prompt": payload.item["prompt"]
        ])
        return AgentSubAgentEvent(
            id: payload.id,
            phase: phase == .terminal ? subAgentPhaseForCompletedStatus(status) : phase,
            description: collabDescription(tool: tool, receivers: receiverThreadIds, prompt: prompt),
            prompt: prompt,
            agentType: "codex",
            input: inputObject([
                "description": .string(collabDescription(tool: tool, receivers: receiverThreadIds, prompt: prompt)),
                "prompt": prompt.map(JSONValue.string),
                "subagent_type": .string("codex"),
                "codex_collab_tool": .string(tool)
            ]),
            lastToolName: tool,
            status: status,
            parentSessionId: payload.item["senderThreadId"]?.codexStringValue,
            childSessionIds: receiverThreadIds.compactMap(\.codexStringValue),
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

    private func subAgentPhaseForCompletedStatus(_ status: String?) -> AgentSubAgentPhase {
        switch status {
        case "inProgress":
            .progress
        default:
            .terminal
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

private extension String {
    var normalizedCollabToolName: String {
        replacingOccurrences(of: "_", with: "").lowercased()
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

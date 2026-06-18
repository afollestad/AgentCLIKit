import Foundation

struct CodexAppServerRawEventNotificationParser {
    private struct RawFunctionCall {
        let name: String
        let threadId: String?
        let turnId: String?
        let prompt: String?
    }

    private var rawFunctionCallsByID: [String: RawFunctionCall] = [:]
    private var rawFunctionOutputsByID: [String: String] = [:]

    mutating func notification(from object: [String: JSONValue]) -> CodexAppServerNotification? {
        if let notification = planNotification(from: object) {
            return notification
        }
        if let notification = responseItemSubAgentNotification(from: object) {
            return notification
        }
        return toolSubAgentNotification(from: object)
    }

    private func planNotification(from object: [String: JSONValue]) -> CodexAppServerNotification? {
        guard object.codexStringValue("type") == "event_msg",
              var payload = object["payload"]?.codexObjectValue,
              let eventType = payload.removeValue(forKey: "type")?.codexStringValue,
              eventType == "item_completed",
              payload["item"]?.codexObjectValue?["type"]?.codexStringValue == "Plan" else {
            return nil
        }
        return CodexAppServerNotification(method: eventType, params: .object(payload))
    }

    private mutating func responseItemSubAgentNotification(from object: [String: JSONValue]) -> CodexAppServerNotification? {
        guard object.codexStringValue("type") == "response_item",
              let payload = object["payload"]?.codexObjectValue,
              let payloadType = payload.codexStringValue("type") else {
            return nil
        }

        switch payloadType {
        case "function_call":
            return rememberSpawnAgentCall(payload)
        case "function_call_output":
            return failedSpawnAgentOutputNotification(payload)
        default:
            break
        }
        return nil
    }

    private mutating func rememberSpawnAgentCall(_ payload: [String: JSONValue]) -> CodexAppServerNotification? {
        guard let callID = payload.codexStringValue("call_id"),
              let name = payload.codexStringValue("name"),
              name.normalizedCodexFunctionName == "spawnagent" else {
            return nil
        }
        let metadata = payload["metadata"]?.codexObjectValue
        let functionCall = RawFunctionCall(
            name: name,
            threadId: metadata?.codexStringValue("thread_id") ?? metadata?.codexStringValue("threadId"),
            turnId: metadata?.codexStringValue("turn_id") ?? metadata?.codexStringValue("turnId"),
            prompt: spawnAgentPrompt(from: payload.codexStringValue("arguments"))
        )
        rawFunctionCallsByID[callID] = functionCall
        if let output = rawFunctionOutputsByID.removeValue(forKey: callID) {
            rawFunctionCallsByID.removeValue(forKey: callID)
            return failedSpawnAgentOutputNotification(callID: callID, functionCall: functionCall, output: output)
        }
        return nil
    }

    private mutating func failedSpawnAgentOutputNotification(_ payload: [String: JSONValue]) -> CodexAppServerNotification? {
        guard let callID = payload.codexStringValue("call_id"),
              let output = payload.codexStringValue("output"),
              !spawnAgentOutputContainsChildAgentID(output) else {
            return nil
        }

        guard let functionCall = rawFunctionCallsByID.removeValue(forKey: callID) else {
            if isRejectedForkedSpawnAgentOutput(output) {
                rawFunctionOutputsByID[callID] = output
            }
            return nil
        }
        return failedSpawnAgentOutputNotification(callID: callID, functionCall: functionCall, output: output)
    }

    private func toolSubAgentNotification(from object: [String: JSONValue]) -> CodexAppServerNotification? {
        guard object.codexStringValue("type") == "tool",
              let payload = object["payload"]?.codexObjectValue,
              let toolName = payload.codexStringValue("tool_name", "toolName"),
              toolName.normalizedCodexFunctionName == "spawnagent",
              let callID = payload.codexStringValue("call_id", "callId"),
              let output = toolOutputText(payload["output"]),
              !spawnAgentOutputContainsChildAgentID(output) else {
            return nil
        }

        let state = payload.codexStringValue("state")
        guard state == nil || state == "output-available" || state == "completed" else {
            return nil
        }
        let metadata = payload["metadata"]?.codexObjectValue
        let input = payload["input"]?.codexObjectValue
        let functionCall = RawFunctionCall(
            name: toolName,
            threadId: metadata?.codexStringValue("thread_id", "threadId"),
            turnId: metadata?.codexStringValue("turn_id", "turnId"),
            prompt: input?.codexStringValue("message")
        )
        return failedSpawnAgentOutputNotification(callID: callID, functionCall: functionCall, output: output)
    }

    private func failedSpawnAgentOutputNotification(
        callID: String,
        functionCall: RawFunctionCall,
        output: String
    ) -> CodexAppServerNotification {
        return CodexAppServerNotification(method: "rawResponseItem/completed", params: .object([
            "thread_id": .string(functionCall.threadId ?? "unknown"),
            "turn_id": .string(functionCall.turnId ?? callID),
            "item": .object([
                "id": .string(callID),
                "type": .string("collabAgentToolCall"),
                "tool": .string(functionCall.name),
                "status": .string("failed"),
                "prompt": functionCall.prompt.map(JSONValue.string) ?? .null,
                "result": .string(output)
            ])
        ]))
    }

    private func spawnAgentPrompt(from arguments: String?) -> String? {
        guard let data = arguments?.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.codexObjectValue else {
            return nil
        }
        return object.codexStringValue("message")
    }

    private func spawnAgentOutputContainsChildAgentID(_ output: String) -> Bool {
        guard let data = output.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.codexObjectValue else {
            return false
        }
        return object.codexStringValue("agent_id") != nil
    }

    private func isRejectedForkedSpawnAgentOutput(_ output: String) -> Bool {
        output.contains("Full-history forked agents inherit")
    }

    private func toolOutputText(_ value: JSONValue?) -> String? {
        let output = textContent(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    private func textContent(_ value: JSONValue?) -> String {
        guard let value else {
            return ""
        }
        switch value {
        case .null:
            return ""
        case let .string(text):
            return text
        case let .array(values):
            return values.map { textContent($0) }.filter { !$0.isEmpty }.joined(separator: "\n")
        case let .object(object):
            return object.codexStringValue("text", "output", "message") ?? ""
        case let .bool(value):
            return String(value)
        case let .number(value):
            return String(value)
        }
    }
}

private extension JSONValue {
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

private extension [String: JSONValue] {
    func codexStringValue(_ key: String) -> String? {
        guard case let .string(value)? = self[key], !value.isEmpty else {
            return nil
        }
        return value
    }

    func codexStringValue(_ keys: String...) -> String? {
        keys.lazy.compactMap { codexStringValue($0) }.first
    }
}

private extension String {
    var normalizedCodexFunctionName: String {
        replacingOccurrences(of: "_", with: "").lowercased()
    }
}

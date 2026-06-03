import Foundation

struct ItemPayload {
    let id: String
    let type: String
    let item: [String: JSONValue]
    let metadata: [String: JSONValue]
}

extension CodexAppServerItemEventDecoder {
    func toolMetadata(_ payload: ItemPayload, values: [String: JSONValue?] = [:]) -> [String: JSONValue] {
        payload.metadata.merging(compacted(values)) { _, new in new }
    }

    func toolResultMetadata(
        _ payload: ItemPayload,
        toolName: String,
        values: [String: JSONValue?] = [:]
    ) -> [String: JSONValue] {
        toolMetadata(payload, values: values.merging([
            "tool_name": .string(toolName),
            "codex_status": payload.item["status"]
        ]) { _, new in new })
    }

    func itemStatus(_ item: [String: JSONValue]) -> String? {
        item["status"]?.codexStringValue
    }

    func nonZeroExitCode(_ item: [String: JSONValue]) -> Bool {
        guard let exitCode = item["exitCode"]?.codexNumberValue else {
            return false
        }
        return exitCode != 0
    }

    func inputObject(_ values: [String: JSONValue?]) -> JSONValue {
        .object(compacted(values))
    }

    func compacted(_ values: [String: JSONValue?]) -> [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value -> (String, JSONValue)? in
            guard let value, value != .null else {
                return nil
            }
            return (key, value)
        })
    }

    func metadata(
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
        metadata.merge(compacted(values)) { _, new in new }
        return metadata
    }

    func runtimeEvent(_ event: AgentEvent) -> AgentProviderRuntimeEvent {
        AgentProviderRuntimeEvent(event: event, source: .runtime)
    }

    func textContent(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return ""
        case let .bool(value):
            return value ? "true" : "false"
        case let .number(value):
            return value.rounded() == value ? String(Int64(value)) : String(value)
        case let .string(value):
            return value
        case let .array(values):
            return values.map(textContent).filter { !$0.isEmpty }.joined(separator: "\n")
        case let .object(object):
            if let text = object["text"]?.codexStringValue {
                return text
            }
            if let message = object["message"]?.codexStringValue {
                return message
            }
            if let output = object["output"] {
                return textContent(output)
            }
            return jsonString(.object(object))
        }
    }

    func jsonString(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }
}

private extension JSONValue {
    var codexStringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }

    var codexNumberValue: Double? {
        guard case let .number(value) = self else {
            return nil
        }
        return value
    }
}

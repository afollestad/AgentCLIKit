import Foundation

extension ClaudeHookRequest {
    var interactionId: AgentInteractionID {
        if let toolUseId = payload.nonEmptyString(forKeys: ["tool_use_id", "toolUseId", "toolUseID"]) {
            return AgentInteractionID(rawValue: toolUseId)
        }
        // Malformed retries without Claude's tool ID must still reuse the same host approval key.
        return AgentInteractionID(rawValue: "hook-\(stableFallbackInteractionFingerprint)")
    }

    var toolName: String {
        payload.objectValue?["tool_name"]?.stringValue
            ?? payload.objectValue?["toolName"]?.stringValue
            ?? "tool"
    }

    var sessionId: AgentSessionID? {
        if let sessionId = payload.objectValue?["session_id"]?.stringValue ?? payload.objectValue?["sessionId"]?.stringValue,
           !sessionId.isEmpty {
            return AgentSessionID(rawValue: sessionId)
        }
        return nil
    }

    var promptText: String? {
        if let question = payload.objectValue?["question"]?.stringValue {
            return question
        }
        return promptQuestionObject?["question"]?.stringValue
    }

    var promptOptions: [AgentPromptOption] {
        promptQuestionObject?["options"]?.arrayValue?.enumerated().compactMap { index, value in
            guard case let .object(option) = value else {
                return nil
            }
            let label = option["label"]?.stringValue
                ?? option["value"]?.stringValue
                ?? option["description"]?.stringValue
                ?? "Option \(index + 1)"
            let responseText = option["value"]?.stringValue ?? option["label"]?.stringValue ?? label
            return AgentPromptOption(
                id: option["id"]?.stringValue ?? "\(index)",
                label: label,
                description: option["description"]?.stringValue,
                responseText: responseText,
                metadata: option
            )
        } ?? []
    }

    var allowsCustomPromptResponse: Bool {
        if let explicit = promptQuestionObject?["allowsCustomResponse"]?.boolValue
            ?? promptQuestionObject?["allowCustomResponse"]?.boolValue {
            return explicit
        }
        return true
    }

    var permissionMode: String? {
        payload.objectValue?["permission_mode"]?.stringValue
            ?? payload.objectValue?["permissionMode"]?.stringValue
    }

    func updatedInputForAllowedOperation(_ operation: String) -> JSONValue? {
        switch operation {
        case "AskUserQuestion", "ExitPlanMode":
            toolInput
        default:
            nil
        }
    }

    var toolInput: JSONValue? {
        payload.objectValue?["tool_input"] ?? payload.objectValue?["toolInput"]
    }

    private var promptQuestionObject: [String: JSONValue]? {
        let toolInput = payload.objectValue?["tool_input"] ?? payload.objectValue?["toolInput"]
        guard case let .array(questions)? = toolInput?.objectValue?["questions"],
              case let .object(firstQuestion)? = questions.first else {
            return nil
        }
        return firstQuestion
    }

    private var stableFallbackInteractionFingerprint: String {
        [
            hookName,
            conversationId.rawValue,
            sessionId?.rawValue ?? "",
            toolName,
            (toolInput ?? payload).canonicalJSONString
        ].joined(separator: "\u{1F}").fnv1a64Hex
    }
}

struct ClaudeHookSettingsPayload: Codable {
    let hooks: [String: [ClaudeHookMatcher]]
}

struct ClaudeHookMatcher: Codable {
    let matcher: String
    let hooks: [ClaudeHookTransport]
}

struct ClaudeHookTransport: Codable {
    let type: String
    let url: String
    let timeout: Int
    let headers: [String: String]
    let allowedEnvVars: [String]
}

extension JSONValue {
    fileprivate func nonEmptyString(forKeys keys: [String]) -> String? {
        guard case let .object(object) = self else {
            return nil
        }
        return keys.lazy.compactMap { key in
            object[key]?.nonEmptyStringValue
        }.first
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else {
            return nil
        }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else {
            return nil
        }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else {
            return nil
        }
        return value
    }

    private var nonEmptyStringValue: String? {
        guard case let .string(value) = self, !value.isEmpty else {
            return nil
        }
        return value
    }

    fileprivate var canonicalJSONString: String {
        switch self {
        case .null:
            return "null"
        case let .bool(value):
            return value ? "true" : "false"
        case let .number(value):
            return Self.jsonEncoded(value) ?? "\(value)"
        case let .string(value):
            return value.canonicalJSONString
        case let .array(values):
            return "[\(values.map(\.canonicalJSONString).joined(separator: ","))]"
        case let .object(values):
            let entries = values.keys.sorted().map { key in
                "\(key.canonicalJSONString):\(values[key]?.canonicalJSONString ?? "null")"
            }
            return "{\(entries.joined(separator: ","))}"
        }
    }

    private static func jsonEncoded<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

private extension String {
    var canonicalJSONString: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return string
    }

    var fnv1a64Hex: String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}

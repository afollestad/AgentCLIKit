import Foundation

extension ClaudeHookRequest {
    var interactionId: AgentInteractionID {
        if let toolUseId = payload.objectValue?["tool_use_id"]?.stringValue ?? payload.objectValue?["toolUseId"]?.stringValue,
           !toolUseId.isEmpty {
            return AgentInteractionID(rawValue: toolUseId)
        }
        return AgentInteractionID(rawValue: UUID().uuidString)
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
}

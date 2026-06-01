import Foundation

extension ClaudeStreamDecoder {
    func attachmentEvents(from envelope: ClaudeStreamEnvelope) -> [AgentEvent] {
        guard let attachment = envelope.attachment else {
            return []
        }
        switch attachment.type {
        case "hook_deferred_tool":
            return hookDeferredToolAttachmentEvents(from: envelope, attachment: attachment)
        case "hook_non_blocking_error":
            return hookErrorAttachmentEvents(from: envelope, attachment: attachment)
        case "queued_command" where attachment.isTaskNotification:
            return taskNotificationEvents(from: attachment.queuedCommandPrompt ?? "")
        default:
            return [.rawOutput(AgentRawOutputEvent(text: "attachment:\(attachment.type)", isComplete: true))]
        }
    }

    private func hookDeferredToolAttachmentEvents(
        from envelope: ClaudeStreamEnvelope,
        attachment: ClaudeAttachment
    ) -> [AgentEvent] {
        guard let sessionId = envelope.sessionId,
              let toolUseId = attachment.toolUseId,
              let toolName = attachment.toolName else {
            return [.diagnostic(AgentDiagnosticEvent(
                severity: .error,
                message: "Malformed Claude event: missing hook_deferred_tool sessionId, toolUseID, or toolName"
            ))]
        }

        var metadata: [String: JSONValue] = [
            "session_id": .string(sessionId),
            "tool_name": .string(toolName),
            "tool_input": attachment.toolInput ?? .object([:])
        ]
        if let parentToolUseId = envelope.parentToolUseId {
            metadata["parent_tool_use_id"] = .string(parentToolUseId)
        }

        return [
            .interaction(AgentInteractionEvent(
                id: AgentInteractionID(rawValue: toolUseId),
                kind: Self.interactionKind(forToolName: toolName),
                prompt: toolName,
                metadata: metadata
            )),
            .usage(AgentUsageEvent(
                model: nil,
                inputTokens: 0,
                outputTokens: 0,
                stopReason: "tool_deferred",
                isTerminal: true,
                metadata: ["stop_reason": .string("tool_deferred")]
            ))
        ]
    }

    private func hookErrorAttachmentEvents(
        from envelope: ClaudeStreamEnvelope,
        attachment: ClaudeAttachment
    ) -> [AgentEvent] {
        let hookName = attachment.hookName ?? "unknown hook"
        let toolName = attachment.toolName ?? toolName(fromHookName: hookName)
        let detail = attachment.stderr ?? attachment.stdout ?? attachment.content ?? "No hook output was provided."
        var metadata: [String: JSONValue] = ["hook_name": .string(hookName)]
        if let sessionId = envelope.sessionId {
            metadata["session_id"] = .string(sessionId)
        }
        if let toolUseId = attachment.toolUseId {
            metadata["tool_use_id"] = .string(toolUseId)
        }
        if let toolName {
            metadata["tool_name"] = .string(toolName)
        }
        return [.diagnostic(AgentDiagnosticEvent(
            code: .hookApprovalFailed,
            severity: .error,
            message: "Claude hook failed (\(hookName)): \(detail)",
            metadata: metadata
        ))]
    }

    private func toolName(fromHookName hookName: String) -> String? {
        guard let separator = hookName.firstIndex(of: ":") else {
            return nil
        }
        let name = hookName[hookName.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

struct ClaudeAttachment: Decodable {
    let type: String
    let toolUseID: String?
    let toolUseIdSnake: String?
    let toolNameCamel: String?
    let toolNameSnake: String?
    let toolInputCamel: JSONValue?
    let toolInputSnake: JSONValue?
    let hookNameCamel: String?
    let hookNameSnake: String?
    let stderr: String?
    let stdout: String?
    let content: String?
    let prompt: String?
    let commandMode: String?
    let commandModeSnake: String?

    var isTaskNotification: Bool {
        commandMode == "task-notification"
            || commandModeSnake == "task-notification"
            || queuedCommandPrompt?.contains("<task-notification>") == true
    }

    var queuedCommandPrompt: String? {
        nonEmpty(prompt) ?? nonEmpty(content)
    }

    var toolUseId: String? {
        nonEmpty(toolUseID) ?? nonEmpty(toolUseIdSnake)
    }

    var toolName: String? {
        nonEmpty(toolNameCamel) ?? nonEmpty(toolNameSnake)
    }

    var toolInput: JSONValue? {
        toolInputCamel ?? toolInputSnake
    }

    var hookName: String? {
        nonEmpty(hookNameCamel) ?? nonEmpty(hookNameSnake)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case toolUseID
        case toolUseIdSnake = "tool_use_id"
        case toolNameCamel = "toolName"
        case toolNameSnake = "tool_name"
        case toolInputCamel = "toolInput"
        case toolInputSnake = "tool_input"
        case hookNameCamel = "hookName"
        case hookNameSnake = "hook_name"
        case stderr
        case stdout
        case content
        case prompt
        case commandMode
        case commandModeSnake = "command_mode"
    }
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else {
        return nil
    }
    return value
}

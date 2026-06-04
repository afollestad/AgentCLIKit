import Foundation

struct CodexAppServerItemEventDecoder {
    // swiftlint:disable:next cyclomatic_complexity
    func decode(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent]? {
        switch notification.method {
        case "item/agentMessage/delta":
            decodeAgentMessageDelta(notification)
        case "item/reasoning/textDelta":
            decodeReasoningTextDelta(notification)
        case "item/reasoning/summaryTextDelta":
            decodeReasoningSummaryTextDelta(notification)
        case "item/reasoning/summaryPartAdded":
            decodeReasoningSummaryPartAdded(notification)
        case "item/started":
            decodeItemStarted(notification)
        case "item/completed":
            decodeItemCompleted(notification)
        case "rawResponseItem/completed":
            decodeRawResponseItemCompleted(notification)
        case "turn/diff/updated":
            decodeTurnDiffUpdated(notification)
        case "item/fileChange/patchUpdated", "fileChange/patch/updated":
            decodeFileChangePatchUpdated(notification)
        case "item/commandExecution/outputDelta":
            decodeCommandExecutionOutputDelta(notification)
        case "item/fileChange/outputDelta":
            decodeFileChangeOutputDelta(notification)
        case "item/mcpToolCall/progress":
            decodeMCPToolCallProgress(notification)
        default:
            nil
        }
    }

    func decodeAgentMessageDelta(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        guard let params = notification.params?.codexObjectValue,
              let delta = params["delta"]?.codexStringValue,
              !delta.isEmpty,
              let metadata = itemDeltaMetadata(notification) else {
            return []
        }
        return [runtimeEvent(.messageDelta(AgentMessageDeltaEvent(role: .assistant, text: delta, metadata: metadata)))]
    }

    func decodeReasoningTextDelta(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        reasoningDeltaEvent(notification, indexKey: "contentIndex", kind: "content")
    }

    func decodeReasoningSummaryTextDelta(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        reasoningDeltaEvent(notification, indexKey: "summaryIndex", kind: "summary")
    }

    func decodeReasoningSummaryPartAdded(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        []
    }

    func decodeItemStarted(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        guard let payload = itemPayload(notification, phase: "started") else {
            return []
        }
        switch payload.type {
        case "commandExecution":
            return [runtimeEvent(commandExecutionToolCall(payload))]
        case "fileChange":
            return [runtimeEvent(fileChangeToolCall(payload))]
        case "mcpToolCall":
            return [runtimeEvent(mcpToolCall(payload))]
        case "dynamicToolCall":
            return [runtimeEvent(dynamicToolCall(payload))]
        case "webSearch":
            return [runtimeEvent(webSearchToolCall(payload))]
        case "collabAgentToolCall":
            return [runtimeEvent(.task(collabAgentTask(payload, phase: .started)))]
        case "contextCompaction":
            return [runtimeEvent(.contextCompaction(contextCompactionEvent(payload, phase: .started)))]
        default:
            return []
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    func decodeItemCompleted(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        guard let payload = itemPayload(notification, phase: "completed") else {
            return []
        }
        switch payload.type {
        case "userMessage":
            return messageEvent(role: .user, text: userMessageText(payload.item), metadata: payload.metadata)
        case "agentMessage":
            return messageEvent(role: .assistant, text: payload.item["text"]?.codexStringValue, metadata: payload.metadata)
        case "reasoning":
            return completedReasoningEvents(payload)
        case "commandExecution":
            return [runtimeEvent(commandExecutionToolResult(payload))]
        case "fileChange":
            return [runtimeEvent(fileChangeToolResult(payload))]
        case "mcpToolCall":
            return [runtimeEvent(mcpToolResult(payload))]
        case "dynamicToolCall":
            return [runtimeEvent(dynamicToolResult(payload))]
        case "webSearch":
            return [runtimeEvent(webSearchToolResult(payload))]
        case "collabAgentToolCall":
            return [runtimeEvent(.task(collabAgentTask(payload, phase: .completed)))]
        case "contextCompaction":
            return [runtimeEvent(.contextCompaction(contextCompactionEvent(payload, phase: .completed)))]
        default:
            return []
        }
    }

    func decodeRawResponseItemCompleted(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        guard let payload = itemPayload(notification, phase: "completed") else {
            return []
        }
        switch payload.type {
        case "compaction_trigger":
            return [runtimeEvent(.contextCompaction(contextCompactionEvent(payload, phase: .started)))]
        case "context_compaction", "compaction":
            return [runtimeEvent(.contextCompaction(contextCompactionEvent(payload, phase: .completed)))]
        default:
            return []
        }
    }

    func decodeTurnDiffUpdated(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        guard let params = notification.params?.codexObjectValue,
              let threadId = params["threadId"]?.codexStringValue,
              let turnId = params["turnId"]?.codexStringValue,
              let diff = params["diff"]?.codexStringValue,
              !diff.isEmpty else {
            return []
        }
        let metadata = metadata(
            method: notification.method,
            threadId: threadId,
            turnId: turnId,
            values: [
                "codex_item_type": .string("turnDiff"),
                "codex_diff_scope": .string("turn")
            ]
        )
        return [runtimeEvent(.toolResult(AgentToolResultEvent(
            id: "codex-turn-diff-\(turnId)",
            isError: false,
            content: diff,
            metadata: metadata
        )))]
    }

    func decodeFileChangePatchUpdated(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        guard let params = notification.params?.codexObjectValue,
              let threadId = params["threadId"]?.codexStringValue,
              let turnId = params["turnId"]?.codexStringValue,
              let itemId = params["itemId"]?.codexStringValue,
              let changes = params["changes"]?.codexArrayValue else {
            return []
        }
        let content = fileChangeText(changes: changes)
        guard !content.isEmpty else {
            return []
        }
        let metadata = metadata(
            method: notification.method,
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            values: [
                "codex_item_type": .string("fileChange"),
                "codex_item_phase": .string("patchUpdated"),
                "codex_diff_scope": .string("item")
            ]
        )
        return [runtimeEvent(.toolResult(AgentToolResultEvent(
            id: itemId,
            isError: false,
            content: content,
            metadata: metadata
        )))]
    }

    func decodeCommandExecutionOutputDelta(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        outputDeltaEvent(notification)
    }

    func decodeFileChangeOutputDelta(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        outputDeltaEvent(notification)
    }

    func decodeMCPToolCallProgress(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        guard let params = notification.params?.codexObjectValue,
              let threadId = params["threadId"]?.codexStringValue,
              let turnId = params["turnId"]?.codexStringValue,
              let itemId = params["itemId"]?.codexStringValue,
              let message = params["message"]?.codexStringValue,
              !message.isEmpty else {
            return []
        }
        let metadata = metadata(
            method: notification.method,
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            values: [
                "codex_item_type": .string("mcpToolCall"),
                "codex_item_phase": .string("progress")
            ]
        )
        return [runtimeEvent(.toolResult(AgentToolResultEvent(
            id: itemId,
            isError: false,
            content: message,
            metadata: metadata
        )))]
    }

    private func reasoningDeltaEvent(
        _ notification: CodexAppServerNotification,
        indexKey: String,
        kind: String
    ) -> [AgentProviderRuntimeEvent] {
        guard let params = notification.params?.codexObjectValue,
              let delta = params["delta"]?.codexStringValue,
              !delta.isEmpty,
              var metadata = itemDeltaMetadata(notification) else {
            return []
        }
        metadata["codex_reasoning_kind"] = .string(kind)
        if let index = params[indexKey] {
            metadata["codex_reasoning_index"] = index
        }
        return [runtimeEvent(.reasoning(AgentReasoningEvent(text: delta, metadata: metadata)))]
    }

    private func outputDeltaEvent(_ notification: CodexAppServerNotification) -> [AgentProviderRuntimeEvent] {
        guard let params = notification.params?.codexObjectValue,
              let delta = params["delta"]?.codexStringValue,
              !delta.isEmpty else {
            return []
        }
        return [runtimeEvent(.rawOutput(AgentRawOutputEvent(text: delta, isComplete: false)))]
    }

    private func itemPayload(_ notification: CodexAppServerNotification, phase: String) -> ItemPayload? {
        guard let params = notification.params?.codexObjectValue,
              let threadId = params["threadId"]?.codexStringValue,
              let turnId = params["turnId"]?.codexStringValue,
              let item = params["item"]?.codexObjectValue,
              let id = item["id"]?.codexStringValue,
              let type = item["type"]?.codexStringValue else {
            return nil
        }
        let itemMetadata = metadata(
            method: notification.method,
            threadId: threadId,
            turnId: turnId,
            itemId: id,
            values: [
                "codex_item_type": .string(type),
                "codex_item_phase": .string(phase),
                "codex_status": item["status"],
                "started_at_ms": params["startedAtMs"],
                "completed_at_ms": params["completedAtMs"]
            ]
        )
        return ItemPayload(id: id, type: type, item: item, metadata: itemMetadata)
    }

    private func itemDeltaMetadata(_ notification: CodexAppServerNotification) -> [String: JSONValue]? {
        guard let params = notification.params?.codexObjectValue,
              let threadId = params["threadId"]?.codexStringValue,
              let turnId = params["turnId"]?.codexStringValue,
              let itemId = params["itemId"]?.codexStringValue else {
            return nil
        }
        return metadata(method: notification.method, threadId: threadId, turnId: turnId, itemId: itemId)
    }

    private func messageEvent(
        role: AgentMessageRole,
        text: String?,
        metadata: [String: JSONValue]
    ) -> [AgentProviderRuntimeEvent] {
        guard let text, !text.isEmpty else {
            return []
        }
        return [runtimeEvent(.message(AgentMessageEvent(role: role, text: text, metadata: metadata)))]
    }

    private func completedReasoningEvents(_ payload: ItemPayload) -> [AgentProviderRuntimeEvent] {
        var events: [AgentProviderRuntimeEvent] = []
        let content = payload.item["content"]?.codexArrayValue?.compactMap(\.codexStringValue).filter { !$0.isEmpty } ?? []
        let summary = payload.item["summary"]?.codexArrayValue?.compactMap(\.codexStringValue).filter { !$0.isEmpty } ?? []
        if !content.isEmpty {
            var metadata = payload.metadata
            metadata["codex_reasoning_kind"] = .string("content")
            events.append(runtimeEvent(.reasoning(AgentReasoningEvent(text: content.joined(separator: "\n"), metadata: metadata))))
        }
        if !summary.isEmpty {
            var metadata = payload.metadata
            metadata["codex_reasoning_kind"] = .string("summary")
            events.append(runtimeEvent(.reasoning(AgentReasoningEvent(text: summary.joined(separator: "\n"), metadata: metadata))))
        }
        return events
    }

    private func userMessageText(_ item: [String: JSONValue]) -> String? {
        guard let content = item["content"]?.codexArrayValue else {
            return nil
        }
        let text = content.compactMap(userInputText).filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private func userInputText(_ value: JSONValue) -> String? {
        guard let object = value.codexObjectValue,
              let type = object["type"]?.codexStringValue else {
            return nil
        }
        switch type {
        case "text":
            return object["text"]?.codexStringValue
        case "image":
            return object["url"]?.codexStringValue.map { "[image: \($0)]" }
        case "localImage":
            return object["path"]?.codexStringValue.map { "[image: \($0)]" }
        case "skill":
            return object["name"]?.codexStringValue.map { "[skill: \($0)]" }
        case "mention":
            return object["name"]?.codexStringValue.map { "@\($0)" }
        default:
            return nil
        }
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

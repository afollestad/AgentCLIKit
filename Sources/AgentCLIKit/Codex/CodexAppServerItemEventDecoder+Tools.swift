import Foundation

extension CodexAppServerItemEventDecoder {
    func commandExecutionToolCall(_ payload: ItemPayload) -> AgentEvent {
        .toolCall(AgentToolCallEvent(
            id: payload.id,
            name: "CommandExecution",
            input: inputObject([
                "command": payload.item["command"],
                "cwd": payload.item["cwd"],
                "commandActions": payload.item["commandActions"],
                "source": payload.item["source"]
            ]),
            metadata: payload.metadata
        ))
    }

    func commandExecutionToolResult(_ payload: ItemPayload) -> AgentEvent {
        .toolResult(AgentToolResultEvent(
            id: payload.id,
            isError: itemStatus(payload.item) == "failed" || nonZeroExitCode(payload.item),
            content: commandExecutionText(payload.item),
            metadata: toolResultMetadata(payload, toolName: "CommandExecution", values: [
                "exit_code": payload.item["exitCode"],
                "duration_ms": payload.item["durationMs"]
            ])
        ))
    }

    func fileChangeToolCall(_ payload: ItemPayload) -> AgentEvent {
        .toolCall(AgentToolCallEvent(
            id: payload.id,
            name: "FileChange",
            input: inputObject(["changes": payload.item["changes"]]),
            metadata: payload.metadata
        ))
    }

    func fileChangeToolResult(_ payload: ItemPayload) -> AgentEvent {
        let changes = payload.item["changes"]?.codexArrayValue ?? []
        return .toolResult(AgentToolResultEvent(
            id: payload.id,
            isError: itemStatus(payload.item) == "failed",
            content: fileChangeText(changes: changes, fallbackStatus: itemStatus(payload.item)),
            metadata: toolResultMetadata(payload, toolName: "FileChange")
        ))
    }

    func mcpToolCall(_ payload: ItemPayload) -> AgentEvent {
        let tool = payload.item["tool"]?.codexStringValue ?? "mcpToolCall"
        return .toolCall(AgentToolCallEvent(
            id: payload.id,
            name: tool,
            input: payload.item["arguments"] ?? .object([:]),
            metadata: toolMetadata(payload, values: [
                "mcp_server": payload.item["server"],
                "mcp_plugin_id": payload.item["pluginId"],
                "mcp_app_resource_uri": payload.item["mcpAppResourceUri"]
            ])
        ))
    }

    func mcpToolResult(_ payload: ItemPayload) -> AgentEvent {
        .toolResult(AgentToolResultEvent(
            id: payload.id,
            isError: itemStatus(payload.item) == "failed" || payload.item["error"]?.codexObjectValue != nil,
            content: mcpToolResultText(payload.item),
            metadata: toolResultMetadata(payload, toolName: payload.item["tool"]?.codexStringValue ?? "mcpToolCall", values: [
                "mcp_server": payload.item["server"],
                "duration_ms": payload.item["durationMs"]
            ])
        ))
    }

    func dynamicToolCall(_ payload: ItemPayload) -> AgentEvent {
        let tool = payload.item["tool"]?.codexStringValue ?? "dynamicToolCall"
        return .toolCall(AgentToolCallEvent(
            id: payload.id,
            name: tool,
            input: payload.item["arguments"] ?? .object([:]),
            metadata: toolMetadata(payload, values: ["namespace": payload.item["namespace"]])
        ))
    }

    func dynamicToolResult(_ payload: ItemPayload) -> AgentEvent {
        .toolResult(AgentToolResultEvent(
            id: payload.id,
            isError: itemStatus(payload.item) == "failed" || payload.item["success"] == .bool(false),
            content: dynamicToolResultText(payload.item),
            metadata: toolResultMetadata(payload, toolName: payload.item["tool"]?.codexStringValue ?? "dynamicToolCall", values: [
                "namespace": payload.item["namespace"],
                "success": payload.item["success"],
                "duration_ms": payload.item["durationMs"]
            ])
        ))
    }

    func webSearchToolCall(_ payload: ItemPayload) -> AgentEvent {
        .toolCall(AgentToolCallEvent(
            id: payload.id,
            name: "WebSearch",
            input: inputObject([
                "query": payload.item["query"],
                "action": payload.item["action"]
            ]),
            metadata: payload.metadata
        ))
    }

    func webSearchToolResult(_ payload: ItemPayload) -> AgentEvent {
        let query = payload.item["query"]?.codexStringValue
        let action = payload.item["action"].map(textContent)
        return .toolResult(AgentToolResultEvent(
            id: payload.id,
            isError: false,
            content: [query.map { "query: \($0)" }, action].compactMap { $0 }.joined(separator: "\n"),
            metadata: toolResultMetadata(payload, toolName: "WebSearch")
        ))
    }

    func commandExecutionText(_ item: [String: JSONValue]) -> String {
        if let output = item["aggregatedOutput"]?.codexStringValue, !output.isEmpty {
            return output
        }
        let command = item["command"]?.codexStringValue.map { "command: \($0)" }
        let status = itemStatus(item).map { "status: \($0)" }
        let exitCode = item["exitCode"].map { "exitCode: \(textContent($0))" }
        return [command, status, exitCode].compactMap { $0 }.joined(separator: "\n")
    }

    func fileChangeText(changes: [JSONValue], fallbackStatus: String? = nil) -> String {
        let changeText = changes.compactMap { change -> String? in
            guard let change = change.codexObjectValue else {
                return nil
            }
            let path = change["path"]?.codexStringValue
            let kind = change["kind"]?.codexObjectValue?["type"]?.codexStringValue
            let diff = change["diff"]?.codexStringValue
            return [path, kind.map { "kind: \($0)" }, diff].compactMap { $0 }.joined(separator: "\n")
        }
        if !changeText.isEmpty {
            return changeText.joined(separator: "\n\n")
        }
        return fallbackStatus.map { "status: \($0)" } ?? ""
    }

    func mcpToolResultText(_ item: [String: JSONValue]) -> String {
        if let errorMessage = item["error"]?.codexObjectValue?["message"]?.codexStringValue, !errorMessage.isEmpty {
            return errorMessage
        }
        if let result = item["result"]?.codexObjectValue {
            if let content = result["content"] {
                let text = textContent(content)
                if !text.isEmpty {
                    return text
                }
            }
            if let structuredContent = result["structuredContent"] {
                return textContent(structuredContent)
            }
            return textContent(.object(result))
        }
        return itemStatus(item) ?? ""
    }

    func dynamicToolResultText(_ item: [String: JSONValue]) -> String {
        if let contentItems = item["contentItems"] {
            let text = textContent(contentItems)
            if !text.isEmpty {
                return text
            }
        }
        return itemStatus(item) ?? item["success"].map { "success: \(textContent($0))" } ?? ""
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

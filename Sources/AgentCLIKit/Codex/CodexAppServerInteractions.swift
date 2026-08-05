import Foundation

struct CodexMappedServerRequest: Sendable {
    let pending: CodexPendingServerRequest
    let event: AgentProviderRuntimeEvent
}

struct CodexPendingServerRequest: Sendable {
    enum Kind: String, Sendable {
        case commandApproval
        case fileChangeApproval
        case permissionProfileApproval
        case mcpElicitation
        case toolUserInput
        case planModeExit
    }

    let requestId: JSONValue
    let interactionId: AgentInteractionID
    let method: String
    let kind: Kind
    let conversationId: AgentConversationID
    let processToken: UUID
    let threadId: AgentSessionID
    let turnId: String?
    let itemId: String?
    let defaultQuestionId: String?
    let params: [String: JSONValue]
}

struct CodexServerRequestMappingContext: Sendable {
    let conversationId: AgentConversationID
    let processToken: UUID
    let threadId: AgentSessionID
    let permissionMode: String?
}

enum CodexServerRequestResolution: Sendable {
    case result(JSONValue)
    case error(code: Int, message: String, data: JSONValue?)
}

struct CodexAppServerServerRequestMapper {
    let commandApprovalNormalizationPolicy: AgentCommandApprovalNormalizationPolicy

    init(commandApprovalNormalizationPolicy: AgentCommandApprovalNormalizationPolicy = .default) {
        self.commandApprovalNormalizationPolicy = commandApprovalNormalizationPolicy
    }

    func map(
        _ request: CodexAppServerRequest,
        context: CodexServerRequestMappingContext
    ) -> CodexMappedServerRequest? {
        guard let params = request.params?.codexObjectValue else {
            return nil
        }
        switch request.method {
        case "item/commandExecution/requestApproval":
            return commandApproval(request, params: params, context: context)
        case "item/fileChange/requestApproval":
            return fileChangeApproval(request, params: params, context: context)
        case "item/permissions/requestApproval":
            return permissionProfileApproval(request, params: params, context: context)
        case "mcpServer/elicitation/request":
            return mcpElicitation(request, params: params, context: context)
        case "item/tool/requestUserInput":
            return toolUserInput(request, params: params, context: context)
        case "item/tool/call":
            return dynamicToolCall(request, params: params, context: context)
        default:
            return nil
        }
    }

    func unsupportedToolCallEvent(_ request: CodexAppServerRequest, threadId: AgentSessionID) -> AgentProviderRuntimeEvent {
        let params = request.params?.codexObjectValue ?? [:]
        return AgentProviderRuntimeEvent(event: .diagnostic(AgentDiagnosticEvent(
            code: .codexAppServerResponseFailure,
            severity: .warning,
            message: "Codex host-defined tool '\(params["tool"]?.codexStringValue ?? "unknown")' is not supported.",
            metadata: compacted([
                "codex_method": .string(request.method),
                "codex_request_id": .string(request.id.codexStableRequestID),
                "codex_thread_id": .string(threadId.rawValue),
                "codex_turn_id": params["turnId"],
                "codex_tool_name": params["tool"],
                "codex_tool_namespace": params["namespace"],
                "codex_tool_call_id": params["callId"]
            ])
        )))
    }

    var unsupportedToolCallResponse: JSONValue {
        .object([
            "success": .bool(false),
            "contentItems": .array([.object([
                "type": .string("inputText"),
                "text": .string("Host-defined Codex tools are not supported by AgentCLIKit.")
            ])])
        ])
    }

    func pendingApproval(
        _ request: CodexAppServerRequest,
        params: [String: JSONValue],
        kind: CodexPendingServerRequest.Kind,
        interactionId: AgentInteractionID,
        context: CodexServerRequestMappingContext
    ) -> CodexPendingServerRequest {
        CodexPendingServerRequest(
            requestId: request.id,
            interactionId: interactionId,
            method: request.method,
            kind: kind,
            conversationId: context.conversationId,
            processToken: context.processToken,
            threadId: context.threadId,
            turnId: params["turnId"]?.codexStringValue,
            itemId: params["itemId"]?.codexStringValue,
            defaultQuestionId: nil,
            params: params
        )
    }

    func approvalMetadata(
        _ request: CodexAppServerRequest,
        params: [String: JSONValue],
        context: CodexServerRequestMappingContext,
        operation: String,
        values: [String: JSONValue?]
    ) -> [String: JSONValue] {
        var metadata = commonMetadata(request, params: params, context: context, values: values)
        metadata["session_id"] = .string(context.threadId.rawValue)
        metadata["tool_name"] = .string(operation)
        metadata["tool_input"] = request.params ?? .object(params)
        metadata["approval_provider_id"] = .string(AgentProviderID.codex.rawValue)
        metadata["approval_operation"] = .string(operation)
        if let permissionMode = context.permissionMode {
            metadata["permission_mode"] = .string(permissionMode)
        }
        return metadata
    }

    func promptMetadata(
        _ request: CodexAppServerRequest,
        params: [String: JSONValue],
        context: CodexServerRequestMappingContext,
        values: [String: JSONValue?]
    ) -> [String: JSONValue] {
        commonMetadata(request, params: params, context: context, values: values)
    }

    func commonMetadata(
        _ request: CodexAppServerRequest,
        params: [String: JSONValue],
        context: CodexServerRequestMappingContext,
        values: [String: JSONValue?]
    ) -> [String: JSONValue] {
        var metadata = compacted(values)
        metadata["provider_id"] = .string(AgentProviderID.codex.rawValue)
        metadata["codex_method"] = .string(request.method)
        metadata["codex_request_id"] = .string(request.id.codexStableRequestID)
        metadata["codex_thread_id"] = .string(context.threadId.rawValue)
        if let turnId = params["turnId"] {
            metadata["codex_turn_id"] = turnId
        }
        if let itemId = params["itemId"] {
            metadata["codex_item_id"] = itemId
        }
        return metadata
    }

    func interactionId(_ request: CodexAppServerRequest) -> AgentInteractionID {
        AgentInteractionID(rawValue: "codex-\(request.method)-\(request.id.codexStableRequestID)")
    }

    func toolCallInteractionId(
        _ request: CodexAppServerRequest,
        params: [String: JSONValue]
    ) -> AgentInteractionID {
        if let callId = params["callId"]?.codexStringValue {
            return AgentInteractionID(rawValue: callId)
        }
        if let itemId = params["itemId"]?.codexStringValue {
            return AgentInteractionID(rawValue: itemId)
        }
        return interactionId(request)
    }

    func toolCallInput(params: [String: JSONValue]) -> JSONValue {
        params["arguments"] ?? params["input"] ?? .object([:])
    }

    func planMarkdown(from value: JSONValue) -> String? {
        guard case let .object(object) = value,
              case let .string(plan)? = object["plan"] else {
            return nil
        }
        return plan.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    func compacted(_ values: [String: JSONValue?]) -> [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value -> (String, JSONValue)? in
            value.map { (key, $0) }
        })
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
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
        guard case let .string(value) = self, !value.isEmpty else {
            return nil
        }
        return value
    }

    var codexStableRequestID: String {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            if value.rounded() == value {
                return String(Int(value))
            }
            return String(value)
        case let .bool(value):
            return String(value)
        case .null:
            return "null"
        case .array, .object:
            guard let data = try? JSONEncoder().encode(self),
                  let string = String(data: data, encoding: .utf8) else {
                return "complex"
            }
            return string
        }
    }
}

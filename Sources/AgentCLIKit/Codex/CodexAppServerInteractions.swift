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

    private func commandApproval(
        _ request: CodexAppServerRequest,
        params: [String: JSONValue],
        context: CodexServerRequestMappingContext
    ) -> CodexMappedServerRequest {
        let interactionId = interactionId(request)
        var metadata = approvalMetadata(
            request,
            params: params,
            context: context,
            operation: "Bash",
            values: [
                "codex_approval_kind": .string("commandExecution"),
                "codex_command": params["command"],
                "codex_command_actions": params["commandActions"],
                "codex_cwd": params["cwd"],
                "codex_reason": params["reason"],
                "codex_available_decisions": .array([
                    .string("accept"),
                    .string("acceptForSession"),
                    .string("acceptWithExecpolicyAmendment"),
                    .string("applyNetworkPolicyAmendment"),
                    .string("decline"),
                    .string("cancel")
                ]),
                "codex_proposed_execpolicy_amendment": params["proposedExecpolicyAmendment"],
                "codex_proposed_network_policy_amendments": params["proposedNetworkPolicyAmendments"],
                "codex_approval_id": params["approvalId"]
            ]
        )
        metadata["codex_supports_session_approval"] = .bool(true)
        let pending = pendingApproval(
            request,
            params: params,
            kind: .commandApproval,
            interactionId: interactionId,
            context: context
        )
        let event = AgentInteractionEvent(id: interactionId, kind: .approval, prompt: "Bash", metadata: metadata)
        return CodexMappedServerRequest(pending: pending, event: AgentProviderRuntimeEvent(event: .interaction(event)))
    }

    private func fileChangeApproval(
        _ request: CodexAppServerRequest,
        params: [String: JSONValue],
        context: CodexServerRequestMappingContext
    ) -> CodexMappedServerRequest {
        let interactionId = interactionId(request)
        var metadata = approvalMetadata(
            request,
            params: params,
            context: context,
            operation: "FileChange",
            values: [
                "codex_approval_kind": .string("fileChange"),
                "codex_reason": params["reason"],
                "codex_grant_root": params["grantRoot"],
                "codex_available_decisions": .array([
                    .string("accept"),
                    .string("acceptForSession"),
                    .string("decline"),
                    .string("cancel")
                ])
            ]
        )
        metadata["codex_supports_session_approval"] = .bool(true)
        let pending = pendingApproval(
            request,
            params: params,
            kind: .fileChangeApproval,
            interactionId: interactionId,
            context: context
        )
        let event = AgentInteractionEvent(id: interactionId, kind: .approval, prompt: "FileChange", metadata: metadata)
        return CodexMappedServerRequest(pending: pending, event: AgentProviderRuntimeEvent(event: .interaction(event)))
    }

    private func permissionProfileApproval(
        _ request: CodexAppServerRequest,
        params: [String: JSONValue],
        context: CodexServerRequestMappingContext
    ) -> CodexMappedServerRequest {
        let interactionId = interactionId(request)
        let metadata = approvalMetadata(
            request,
            params: params,
            context: context,
            operation: "Permissions",
            values: [
                "codex_approval_kind": .string("permissionProfile"),
                "codex_cwd": params["cwd"],
                "codex_reason": params["reason"],
                "codex_permissions": params["permissions"],
                "codex_available_decisions": .array([
                    .string("grantForTurn"),
                    .string("grantForSession"),
                    .string("deny")
                ]),
                "codex_denial_fallback": .string("jsonRPCError")
            ]
        )
        let pending = pendingApproval(
            request,
            params: params,
            kind: .permissionProfileApproval,
            interactionId: interactionId,
            context: context
        )
        let event = AgentInteractionEvent(id: interactionId, kind: .approval, prompt: "Permissions", metadata: metadata)
        return CodexMappedServerRequest(pending: pending, event: AgentProviderRuntimeEvent(event: .interaction(event)))
    }

    private func mcpElicitation(
        _ request: CodexAppServerRequest,
        params: [String: JSONValue],
        context: CodexServerRequestMappingContext
    ) -> CodexMappedServerRequest {
        let interactionId = interactionId(request)
        var metadata = promptMetadata(request, params: params, context: context, values: [
            "codex_prompt_kind": .string("mcpElicitation"),
            "mcp_server_name": params["serverName"],
            "mcp_elicitation_mode": params["mode"],
            "mcp_elicitation_id": params["elicitationId"],
            "mcp_elicitation_url": params["url"],
            "mcp_requested_schema": params["requestedSchema"],
            "mcp_meta": params["_meta"]
        ])
        metadata["codex_available_actions"] = .array([.string("accept"), .string("decline"), .string("cancel")])
        let pending = CodexPendingServerRequest(
            requestId: request.id,
            interactionId: interactionId,
            method: request.method,
            kind: .mcpElicitation,
            conversationId: context.conversationId,
            processToken: context.processToken,
            threadId: context.threadId,
            turnId: params["turnId"]?.codexStringValue,
            itemId: params["elicitationId"]?.codexStringValue,
            defaultQuestionId: nil,
            params: params
        )
        let event = AgentInteractionEvent(
            id: interactionId,
            kind: .prompt,
            prompt: params["message"]?.codexStringValue ?? "Codex requested MCP input.",
            metadata: metadata
        )
        return CodexMappedServerRequest(pending: pending, event: AgentProviderRuntimeEvent(event: .interaction(event)))
    }

    private func toolUserInput(
        _ request: CodexAppServerRequest,
        params: [String: JSONValue],
        context: CodexServerRequestMappingContext
    ) -> CodexMappedServerRequest {
        let interactionId = interactionId(request)
        let questions = params["questions"]?.codexArrayValue ?? []
        let firstQuestion = questions.first?.codexObjectValue
        let defaultQuestionId = firstQuestion?["id"]?.codexStringValue
        var metadata = promptMetadata(request, params: params, context: context, values: [
            "codex_prompt_kind": .string("toolRequestUserInput"),
            "codex_item_id": params["itemId"],
            "codex_questions": params["questions"],
            "codex_default_question_id": defaultQuestionId.map(JSONValue.string)
        ])
        metadata["session_id"] = .string(context.threadId.rawValue)
        metadata["tool_name"] = .string("AskUserQuestion")
        metadata["tool_input"] = request.params ?? .object(params)
        metadata["codex_available_actions"] = .array([.string("answer"), .string("cancel")])
        let pending = CodexPendingServerRequest(
            requestId: request.id,
            interactionId: interactionId,
            method: request.method,
            kind: .toolUserInput,
            conversationId: context.conversationId,
            processToken: context.processToken,
            threadId: context.threadId,
            turnId: params["turnId"]?.codexStringValue,
            itemId: params["itemId"]?.codexStringValue,
            defaultQuestionId: defaultQuestionId,
            params: params
        )
        let prompt = firstQuestion?["question"]?.codexStringValue ?? "Codex requested input."
        let event = AgentInteractionEvent(
            id: interactionId,
            kind: .prompt,
            prompt: prompt,
            promptOptions: promptOptions(from: firstQuestion),
            metadata: metadata
        )
        return CodexMappedServerRequest(pending: pending, event: AgentProviderRuntimeEvent(event: .interaction(event)))
    }

    private func dynamicToolCall(
        _ request: CodexAppServerRequest,
        params: [String: JSONValue],
        context: CodexServerRequestMappingContext
    ) -> CodexMappedServerRequest? {
        guard params["tool"]?.codexStringValue == "ExitPlanMode" else {
            return nil
        }

        let interactionId = toolCallInteractionId(request, params: params)
        let toolInput = toolCallInput(params: params)
        let planMarkdown = planMarkdown(from: toolInput)
        var metadata = approvalMetadata(
            request,
            params: params,
            context: context,
            operation: "ExitPlanMode",
            values: [
                "codex_prompt_kind": .string("toolExitPlanMode"),
                "codex_tool_name": params["tool"],
                "codex_tool_namespace": params["namespace"],
                "codex_tool_call_id": params["callId"],
                "codex_tool_arguments": params["arguments"],
                "codex_available_actions": .array([.string("accept"), .string("decline")]),
                "plan": planMarkdown.map(JSONValue.string)
            ]
        )
        metadata["tool_input"] = toolInput

        let pending = CodexPendingServerRequest(
            requestId: request.id,
            interactionId: interactionId,
            method: request.method,
            kind: .planModeExit,
            conversationId: context.conversationId,
            processToken: context.processToken,
            threadId: context.threadId,
            turnId: params["turnId"]?.codexStringValue,
            itemId: params["callId"]?.codexStringValue ?? params["itemId"]?.codexStringValue,
            defaultQuestionId: nil,
            params: params
        )
        let event = AgentInteractionEvent(
            id: interactionId,
            kind: .planModeExit,
            prompt: "ExitPlanMode",
            metadata: metadata
        )
        return CodexMappedServerRequest(pending: pending, event: AgentProviderRuntimeEvent(event: .interaction(event)))
    }

    private func promptOptions(from question: [String: JSONValue]?) -> [AgentPromptOption] {
        question?["options"]?.codexArrayValue?.enumerated().compactMap { index, value in
            guard let option = value.codexObjectValue else {
                return nil
            }
            let label = option["label"]?.codexStringValue
                ?? option["value"]?.codexStringValue
                ?? option["description"]?.codexStringValue
                ?? "Option \(index + 1)"
            let responseText = option["value"]?.codexStringValue ?? option["label"]?.codexStringValue ?? label
            return AgentPromptOption(
                id: option["id"]?.codexStringValue ?? "\(index)",
                label: label,
                description: option["description"]?.codexStringValue,
                responseText: responseText,
                metadata: option
            )
        } ?? []
    }

    private func pendingApproval(
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

    private func approvalMetadata(
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

    private func promptMetadata(
        _ request: CodexAppServerRequest,
        params: [String: JSONValue],
        context: CodexServerRequestMappingContext,
        values: [String: JSONValue?]
    ) -> [String: JSONValue] {
        commonMetadata(request, params: params, context: context, values: values)
    }

    private func commonMetadata(
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

    private func interactionId(_ request: CodexAppServerRequest) -> AgentInteractionID {
        AgentInteractionID(rawValue: "codex-\(request.method)-\(request.id.codexStableRequestID)")
    }

    private func toolCallInteractionId(
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

    private func toolCallInput(params: [String: JSONValue]) -> JSONValue {
        params["arguments"] ?? params["input"] ?? .object([:])
    }

    private func planMarkdown(from value: JSONValue) -> String? {
        guard case let .object(object) = value,
              case let .string(plan)? = object["plan"] else {
            return nil
        }
        return plan.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func compacted(_ values: [String: JSONValue?]) -> [String: JSONValue] {
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

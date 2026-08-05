import Foundation

/// Maps each Codex server-request kind to its provider-neutral interaction event.
extension CodexAppServerServerRequestMapper {
    func commandApproval(
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
                "codex_approval_id": params["approvalId"],
                "approval_identity_tool_input": commandApprovalNormalizationPolicy.normalizedApprovalIdentityToolInput(
                    toolName: "Bash",
                    toolInput: .object(params)
                )
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

    func fileChangeApproval(
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

    func permissionProfileApproval(
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

    func mcpElicitation(
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

    func toolUserInput(
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

    func dynamicToolCall(
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

    func promptOptions(from question: [String: JSONValue]?) -> [AgentPromptOption] {
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
}

// Mirrors the accessors in `CodexAppServerInteractions.swift`; `codexStringValue` treats an empty
// string as absent, which the item-event decoders' same-named accessors deliberately do not.
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
}

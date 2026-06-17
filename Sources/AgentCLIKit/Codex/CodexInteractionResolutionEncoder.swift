import Foundation

struct CodexInteractionResolutionEncoder {
    func resolution(_ resolution: AgentInteractionResolution, for pending: CodexPendingServerRequest) -> CodexServerRequestResolution {
        switch pending.kind {
        case .commandApproval:
            return .result(.object(["decision": commandDecision(resolution)]))
        case .fileChangeApproval:
            return .result(.object(["decision": fileChangeDecision(resolution)]))
        case .permissionProfileApproval:
            return permissionProfileResolution(resolution, for: pending)
        case .mcpElicitation:
            return .result(mcpElicitationResponse(resolution))
        case .toolUserInput:
            return toolUserInputResolution(resolution, for: pending)
        case .planModeExit:
            return .result(planModeExitResponse(resolution))
        }
    }

    private func commandDecision(_ resolution: AgentInteractionResolution) -> JSONValue {
        if let explicitDecision = explicitDecision(resolution) {
            return explicitDecision
        }
        switch resolution.outcome {
        case .approved, .answered:
            return approvalGrantKind(resolution) == "session" ? .string("acceptForSession") : .string("accept")
        case .denied, .deferred:
            return .string("decline")
        case .cancelled:
            return .string("cancel")
        }
    }

    private func fileChangeDecision(_ resolution: AgentInteractionResolution) -> JSONValue {
        if let explicitDecision = explicitDecision(resolution) {
            return explicitDecision
        }
        switch resolution.outcome {
        case .approved, .answered:
            return approvalGrantKind(resolution) == "session" ? .string("acceptForSession") : .string("accept")
        case .denied, .deferred:
            return .string("decline")
        case .cancelled:
            return .string("cancel")
        }
    }

    private func permissionProfileResolution(
        _ resolution: AgentInteractionResolution,
        for pending: CodexPendingServerRequest
    ) -> CodexServerRequestResolution {
        switch resolution.outcome {
        case .approved, .answered:
            var result: [String: JSONValue] = [
                "permissions": permissionGrant(resolution, fallback: pending.params["permissions"])
            ]
            result["scope"] = .string(permissionScope(resolution))
            if let strictAutoReview = resolution.metadata["codex_strict_auto_review"]
                ?? resolution.metadata["strictAutoReview"] {
                result["strictAutoReview"] = strictAutoReview
            }
            return .result(.object(result))
        case .denied, .deferred, .cancelled:
            return .error(
                code: -32000,
                message: resolution.outcome == .cancelled
                    ? "Codex permission grant was cancelled by the host."
                    : "Codex permission grant was denied by the host.",
                data: .object([
                    "codex_method": .string(pending.method),
                    "codex_denial_fallback": .string("jsonRPCError")
                ])
            )
        }
    }

    private func mcpElicitationResponse(_ resolution: AgentInteractionResolution) -> JSONValue {
        let action: String
        switch resolution.outcome {
        case .approved, .answered:
            action = "accept"
        case .denied, .deferred:
            action = "decline"
        case .cancelled:
            action = "cancel"
        }

        var response: [String: JSONValue] = ["action": .string(action)]
        if action == "accept" {
            response["content"] = resolution.metadata["codex_content"]
                ?? resolution.metadata["content"]
                ?? resolution.responseText.map(JSONValue.string)
                ?? .object([:])
        }
        if let meta = resolution.metadata["codex_meta"] ?? resolution.metadata["_meta"] {
            response["_meta"] = meta
        }
        return .object(response)
    }

    private func toolUserInputResolution(
        _ resolution: AgentInteractionResolution,
        for pending: CodexPendingServerRequest
    ) -> CodexServerRequestResolution {
        switch resolution.outcome {
        case .approved, .answered:
            return .result(.object(["answers": .object(toolUserInputAnswers(resolution, pending: pending))]))
        case .denied, .deferred, .cancelled:
            return .error(
                code: -32000,
                message: "Codex user input request was cancelled by the host.",
                data: .object(["codex_method": .string(pending.method)])
            )
        }
    }

    private func toolUserInputAnswers(
        _ resolution: AgentInteractionResolution,
        pending: CodexPendingServerRequest
    ) -> [String: JSONValue] {
        if case let .object(answers)? = resolution.metadata["codex_answers"] {
            return answers
        }
        if let answers = normalizedToolUserInputAnswers(from: resolution.metadata["updated_input"], pending: pending) {
            return answers
        }
        if let answers = normalizedToolUserInputAnswers(from: resolution.metadata["answers"], pending: pending) {
            return answers
        }
        guard let questionId = pending.defaultQuestionId,
              let responseText = resolution.responseText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !responseText.isEmpty else {
            return [:]
        }
        return [
            questionId: .object(["answers": .array([.string(responseText)])])
        ]
    }

    private func normalizedToolUserInputAnswers(
        from value: JSONValue?,
        pending: CodexPendingServerRequest
    ) -> [String: JSONValue]? {
        guard let answerObject = toolUserInputAnswerObject(from: value) else {
            return nil
        }
        let keyMap = toolUserInputQuestionKeyMap(pending: pending)
        let normalized = answerObject.reduce(into: [String: JSONValue]()) { partialResult, entry in
            guard let answer = normalizedToolUserInputAnswerValue(entry.value) else {
                return
            }
            partialResult[keyMap[entry.key] ?? entry.key] = answer
        }
        return normalized.isEmpty ? nil : normalized
    }

    private func toolUserInputAnswerObject(from value: JSONValue?) -> [String: JSONValue]? {
        guard let value else {
            return nil
        }
        if case let .object(object) = value {
            if case let .object(answers)? = object["answers"] {
                return answers
            }
            return object
        }
        return nil
    }

    private func toolUserInputQuestionKeyMap(pending: CodexPendingServerRequest) -> [String: String] {
        let questions = pending.params["questions"]?.codexArrayValue ?? []
        return questions.reduce(into: [String: String]()) { partialResult, value in
            guard let question = value.codexObjectValue,
                  let id = question["id"]?.codexStringValue else {
                return
            }
            partialResult[id] = id
            if let text = question["question"]?.codexStringValue {
                partialResult[text] = id
            }
        }
    }

    private func planModeExitResponse(_ resolution: AgentInteractionResolution) -> JSONValue {
        switch resolution.outcome {
        case .approved, .answered:
            return dynamicToolCallResponse(
                success: true,
                text: resolution.responseText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? "Plan approved by the host."
            )
        case .denied, .deferred:
            return dynamicToolCallResponse(
                success: false,
                text: resolution.responseText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? "The host chose to stay in plan mode."
            )
        case .cancelled:
            return dynamicToolCallResponse(success: false, text: "The host cancelled the plan mode exit.")
        }
    }

    private func dynamicToolCallResponse(success: Bool, text: String) -> JSONValue {
        .object([
            "success": .bool(success),
            "contentItems": .array([.object([
                "type": .string("inputText"),
                "text": .string(text)
            ])])
        ])
    }

    private func normalizedToolUserInputAnswerValue(_ value: JSONValue) -> JSONValue? {
        switch value {
        case .string(let answer):
            return .object(["answers": .array([.string(answer)])])
        case .array(let answers):
            var stringAnswers: [JSONValue] = []
            for answer in answers {
                guard case .string = answer else {
                    return nil
                }
                stringAnswers.append(answer)
            }
            return .object(["answers": .array(stringAnswers)])
        case .object(let object):
            guard object["answers"] != nil else {
                return nil
            }
            return .object(object)
        case .null, .bool, .number:
            return nil
        }
    }

    private func explicitDecision(_ resolution: AgentInteractionResolution) -> JSONValue? {
        resolution.metadata["codex_decision"] ?? resolution.metadata["codex_approval_decision"]
    }

    private func approvalGrantKind(_ resolution: AgentInteractionResolution) -> String? {
        resolution.metadata["approval_grant_kind"]?.codexStringValue
    }

    private func permissionGrant(_ resolution: AgentInteractionResolution, fallback: JSONValue?) -> JSONValue {
        resolution.metadata["codex_permissions"]
            ?? resolution.metadata["permissions"]
            ?? fallback
            ?? .object([:])
    }

    private func permissionScope(_ resolution: AgentInteractionResolution) -> String {
        if let scope = resolution.metadata["codex_permission_scope"]?.codexStringValue
            ?? resolution.metadata["permission_scope"]?.codexStringValue {
            return scope
        }
        return approvalGrantKind(resolution) == "session" ? "session" : "turn"
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
}

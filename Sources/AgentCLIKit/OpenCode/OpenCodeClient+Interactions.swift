import Foundation

/// Native request IDs stay process-scoped and resolved requests cannot reopen after reconnect.
extension OpenCodeClient {
    func interaction(_ kind: String, payload: JSONValue, state: OpenCodeGeneration) async {
        guard let id = payload[oc: "id"]?.ocString, let sessionID = payload[oc: "sessionID"]?.ocString,
              state.translator.contains(sessionID: sessionID), state.pendingInteractions[id] == nil,
              !state.resolvedInteractions.contains(id), (try? Self.validateID(id)) != nil else { return }
        state.pendingInteractions[id] = OpenCodePendingInteraction(kind: kind, payload: payload)
        var metadata: [String: JSONValue] = [
            "session_id": .string(sessionID), "opencode_request_id": .string(id),
            "opencode_session_id": .string(sessionID), "approval_provider_id": .string("opencode")
        ]
        if let tool = payload[oc: "tool"], let messageID = tool[oc: "messageID"]?.ocString,
           let callID = tool[oc: "callID"]?.ocString {
            metadata["tool_use_id"] = .string(state.translator.toolID(sessionID: sessionID, messageID: messageID, callID: callID))
        }
        let event: AgentInteractionEvent
        if kind == "permission" {
            let nativeName = payload[oc: "permission"]?.ocString ?? "tool"
            let toolName = nativeName == "bash" ? "Bash" : nativeName
            let toolInput = payload[oc: "metadata"] ?? .object([:])
            let identity = configuration.commandApprovalNormalizationPolicy.normalizedApprovalIdentityToolInput(
                toolName: toolName, toolInput: toolInput
            )
            let request = AgentSessionApprovalRequest(
                harnessId: .opencode, conversationId: state.context.conversationId,
                sessionId: AgentSessionID(rawValue: sessionID), toolName: toolName, toolInput: toolInput,
                approvalIdentityToolInput: identity
            )
            if await handleAutomaticApproval(request, id: id, state: state) { return }
            metadata["tool_name"] = .string(toolName)
            metadata["tool_input"] = toolInput
            metadata["approval_identity_tool_input"] = identity
            metadata["approval_operation"] = .string(toolName)
            metadata["opencode_patterns"] = payload[oc: "patterns"]
            metadata["permission_mode"] = .string(state.context.spawnConfig.permissionMode ?? "ask")
            event = AgentInteractionEvent(id: AgentInteractionID(rawValue: id), kind: .approval, prompt: toolName, metadata: metadata)
        } else {
            event = questionEvent(id: id, payload: payload, metadata: metadata)
        }
        guard generations[state.context.processToken] === state, state.pendingInteractions[id] != nil else { return }
        emit(.interaction(event), state: state)
    }

    /// Returns true when approval succeeded or its outcome is unknown, so only confirmed pending requests reach the host UI.
    private func handleAutomaticApproval(_ request: AgentSessionApprovalRequest, id: String, state: OpenCodeGeneration) async -> Bool {
        guard await configuration.sessionApprovalPolicyStore.allowsSessionApproval(request) else { return false }
        guard generations[state.context.processToken] === state else { return true }
        do {
            _ = try await state.transport.request(method: "POST", path: "/permission/\(id)/reply", body: .object(["reply": .string("once")]))
            state.pendingInteractions[id] = nil
            state.resolvedInteractions.insert(id)
            return true
        } catch {
            switch await recoverInteractionResolution(id: id, kind: "permission", state: state) {
            case .resolved: return true
            case .pending: return false
            case .unavailable:
                failInteractionRecovery(state)
                return true
            }
        }
    }

    private func questionEvent(id: String, payload: JSONValue, metadata: [String: JSONValue]) -> AgentInteractionEvent {
        var metadata = metadata
        let questions = payload[oc: "questions"]?.ocArray ?? []
        // The shared prompt UI consumes the same structured question shape as AskUserQuestion.
        let normalized = questions.enumerated().map { index, question -> JSONValue in
            var value = question.ocObject ?? [:]
            value["id"] = .string(String(index))
            value["multiSelect"] = question[oc: "multiple"] ?? .bool(false)
            return .object(value)
        }
        metadata["tool_name"] = .string("AskUserQuestion")
        metadata["tool_input"] = .object(["questions": .array(normalized)])
        metadata["opencode_questions"] = .array(normalized)
        let first = questions.first
        let options = (first?[oc: "options"]?.ocArray ?? []).compactMap { value -> AgentPromptOption? in
            guard let label = value[oc: "label"]?.ocString else { return nil }
            return AgentPromptOption(id: label, label: label, description: value[oc: "description"]?.ocString, responseText: label)
        }
        return AgentInteractionEvent(
            id: AgentInteractionID(rawValue: id), kind: .prompt, prompt: first?[oc: "question"]?.ocString ?? "OpenCode requested input.",
            promptOptions: options, metadata: metadata
        )
    }

    func resolve(_ resolution: AgentInteractionResolution, state: OpenCodeGeneration) async throws {
        let id = resolution.id.rawValue
        guard let pending = state.pendingInteractions[id] else {
            throw AgentCLIError.invalidInput("This OpenCode request is no longer pending.")
        }
        let approved = resolution.outcome == .approved || resolution.outcome == .answered
        let path: String
        let body: JSONValue?
        if pending.kind == "permission" {
            path = "/permission/\(id)/reply"
            let reuse = resolution.metadata["approval_grant_kind"]?.ocString == "session"
                && resolution.metadata["approval_session_scope"] == nil
            body = .object(["reply": .string(approved ? (reuse ? "always" : "once") : "reject")])
        } else if approved {
            path = "/question/\(id)/reply"
            body = .object(["answers": .array(try questionAnswers(resolution, pending: pending).map { .array($0.map(JSONValue.string)) })])
        } else {
            path = "/question/\(id)/reject"
            body = nil
        }
        do {
            _ = try await state.transport.request(method: "POST", path: path, body: body)
            state.pendingInteractions[id] = nil
            state.resolvedInteractions.insert(id)
        } catch {
            // No blind retry of answers or approvals after a lost response.
            switch await recoverInteractionResolution(id: id, kind: pending.kind, state: state) {
            case .resolved: return
            case .pending: break
            case .unavailable: failInteractionRecovery(state)
            }
            throw error
        }
    }

    private func failInteractionRecovery(_ state: OpenCodeGeneration) {
        state.failed = true
        let message = "Interaction reply acceptance is unknown. Resume this session before continuing."
        if state.active { finishTurn(state, error: message) } else {
            emit(.lifecycle(AgentLifecycleEvent(state: .failed, message: message)), state: state)
        }
    }

    /// A lost reply response must not surface an already-resolved request as a new host interaction.
    private func recoverInteractionResolution(id: String, kind: String, state: OpenCodeGeneration) async -> OpenCodeInteractionRecovery {
        for attempt in 0..<3 {
            if state.resolvedInteractions.contains(id) { return .resolved }
            do {
                let remaining = try await state.transport.request(method: "GET", path: "/\(kind)", body: nil)
                if state.resolvedInteractions.contains(id) { return .resolved }
                guard let requests = remaining.ocArray else { throw OpenCodeTransportError.invalidResponse("Invalid pending interactions.") }
                if requests.contains(where: { $0[oc: "id"]?.ocString == id }) { return .pending }
                state.pendingInteractions[id] = nil
                state.resolvedInteractions.insert(id)
                return .resolved
            } catch is CancellationError { return .unavailable } catch {
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(100 * (attempt + 1))) }
            }
        }
        return state.resolvedInteractions.contains(id) ? .resolved : .unavailable
    }

    func questionAnswers(_ resolution: AgentInteractionResolution, pending: OpenCodePendingInteraction) throws -> [[String]] {
        let questions = pending.payload[oc: "questions"]?.ocArray ?? []
        if let explicit = resolution.metadata["opencode_answers"]?.ocArray {
            let answers = explicit.map { ($0.ocArray ?? []).compactMap(\.ocString) }
            guard answers.count == questions.count else { throw AgentCLIError.invalidInput("Answer every OpenCode question.") }
            return try validatedQuestionAnswers(answers, questions: questions)
        }
        let updated = resolution.metadata["updated_input"]
        let answers = updated?[oc: "answers"]?.ocObject ?? resolution.metadata["answers"]?.ocObject ?? [:]
        let normalized: [[String]] = try questions.enumerated().map { index, question in
            let value = answers[String(index)] ?? answers[question[oc: "question"]?.ocString ?? ""]
            if let values = value?.ocArray { return values.compactMap(\.ocString) }
            if let text = value?.ocString { return [text] }
            if questions.count == 1, let text = resolution.responseText, !text.isEmpty { return [text] }
            throw AgentCLIError.invalidInput("Answer every OpenCode question before submitting.")
        }
        return try validatedQuestionAnswers(normalized, questions: questions)
    }

    private func validatedQuestionAnswers(_ answers: [[String]], questions: [JSONValue]) throws -> [[String]] {
        for (question, answer) in zip(questions, answers) {
            guard !answer.isEmpty, answer.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  question[oc: "multiple"]?.ocBool == true || answer.count == 1 else {
                throw AgentCLIError.invalidInput("Choose an answer for every OpenCode question.")
            }
            if question[oc: "custom"]?.ocBool == false {
                let labels = Set((question[oc: "options"]?.ocArray ?? []).compactMap { $0[oc: "label"]?.ocString })
                guard answer.allSatisfy(labels.contains) else {
                    throw AgentCLIError.invalidInput("This OpenCode question requires one of its listed choices.")
                }
            }
        }
        return answers
    }
}

private enum OpenCodeInteractionRecovery { case resolved, pending, unavailable }

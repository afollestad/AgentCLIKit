import Foundation

extension DefaultAgentRuntime {
    static func subAgentPhaseKey(_ subAgent: AgentSubAgentEvent) -> String {
        [
            subAgent.id,
            subAgent.phase.rawValue,
            subAgent.description ?? "",
            subAgent.prompt ?? "",
            subAgent.agentType ?? "",
            subAgent.lastToolName ?? "",
            subAgent.status ?? "",
            subAgent.result ?? "",
            subAgent.toolUses.map(String.init) ?? "",
            subAgent.totalTokens.map(String.init) ?? "",
            subAgent.durationMs.map(String.init) ?? "",
            subAgent.parentToolUseId ?? "",
            subAgent.callerAgent ?? "",
            subAgent.parentSessionId ?? "",
            subAgent.childSessionIds.joined(separator: ","),
            subAgentJSONKeyPart(subAgent.input),
            subAgentJSONKeyPart(.object(subAgent.metadata))
        ].joined(separator: "\u{1F}")
    }

    func lifecycleGuardedEvents(from event: AgentEvent, conversationId: AgentConversationID) -> [AgentEvent] {
        contextCompactionGuardedEvents(from: event, conversationId: conversationId).flatMap {
            subAgentGuardedEvents(from: $0, conversationId: conversationId)
        }.flatMap {
            turnEndSubAgentGuardedEvents(from: $0, conversationId: conversationId)
        }
    }

    func subAgentGuardedEvents(from event: AgentEvent, conversationId: AgentConversationID) -> [AgentEvent] {
        guard case let .subAgent(subAgent) = event else {
            return [event]
        }
        guard var state = states[conversationId] else {
            return []
        }

        let phaseKey = Self.subAgentPhaseKey(subAgent)
        guard !state.subAgentPhaseKeys.contains(phaseKey) else {
            states[conversationId] = state
            return []
        }
        guard !state.subAgentTerminalIds.contains(subAgent.id) else {
            states[conversationId] = state
            return []
        }

        switch subAgent.phase {
        case .started:
            state.subAgentStartedIds.insert(subAgent.id)
            state.subAgentOpenIds.insert(subAgent.id)
        case .progress:
            state.subAgentOpenIds.insert(subAgent.id)
        case .terminal:
            state.subAgentOpenIds.remove(subAgent.id)
            state.subAgentTerminalIds.insert(subAgent.id)
        }
        state.subAgentPhaseKeys.insert(phaseKey)

        let terminalFailure = !subAgent.phase.isTerminal && state.lifecycleState.isTerminal
            ? terminalFailure(for: subAgent.id, state: &state, lifecycleState: state.lifecycleState)
            : nil
        states[conversationId] = state

        var events = [event]
        if let terminalFailure {
            events.append(.subAgent(terminalFailure))
        }
        return events
    }

    func turnEndSubAgentGuardedEvents(from event: AgentEvent, conversationId: AgentConversationID) -> [AgentEvent] {
        guard event.endsProviderTurn,
              var state = states[conversationId],
              !state.subAgentOpenIds.isEmpty else {
            return [event]
        }

        // Codex can emit a spawnAgent start for a rejected spawn without a matching
        // completion item. Close only those Codex spawn rows when the turn ends.
        var terminalEvents: [AgentEvent] = []
        for id in state.subAgentOpenIds.sorted() {
            if let terminal = turnEndTerminal(for: id, state: &state) {
                terminalEvents.append(.subAgent(terminal))
            }
        }
        states[conversationId] = state
        return [event] + terminalEvents
    }

    func emitFailedSubAgentsForTerminalProcess(
        conversationId: AgentConversationID,
        reason: String,
        message: String
    ) {
        guard let state = states[conversationId], !state.subAgentOpenIds.isEmpty else {
            return
        }
        for id in state.subAgentOpenIds.sorted() {
            let failed = AgentSubAgentEvent(
                id: id,
                phase: .terminal,
                status: "failed",
                result: message,
                metadata: [
                    "synthetic": .bool(true),
                    "terminal_reason": .string(reason)
                ]
            )
            for event in subAgentGuardedEvents(from: .subAgent(failed), conversationId: conversationId) {
                append(event, source: .runtime, conversationId: conversationId)
            }
        }
    }

    private func terminalFailure(
        for id: String,
        state: inout ConversationState,
        lifecycleState: AgentLifecycleState
    ) -> AgentSubAgentEvent? {
        let failed = AgentSubAgentEvent(
            id: id,
            phase: .terminal,
            status: "failed",
            result: terminalFailureMessage(for: lifecycleState),
            metadata: [
                "synthetic": .bool(true),
                "terminal_reason": .string(lifecycleState.rawValue)
            ]
        )
        let failedPhaseKey = Self.subAgentPhaseKey(failed)
        guard !state.subAgentPhaseKeys.contains(failedPhaseKey),
              !state.subAgentTerminalIds.contains(id) else {
            return nil
        }
        state.subAgentOpenIds.remove(id)
        state.subAgentTerminalIds.insert(id)
        state.subAgentPhaseKeys.insert(failedPhaseKey)
        return failed
    }

    private func turnEndTerminal(for id: String, state: inout ConversationState) -> AgentSubAgentEvent? {
        guard let subAgent = latestOpenSubAgent(id: id, state: state),
              isCodexSpawnSubAgent(subAgent) else {
            return nil
        }

        var metadata = subAgent.metadata
        metadata["synthetic"] = .bool(true)
        metadata["terminal_reason"] = .string("turn_end")
        let terminal = AgentSubAgentEvent(
            id: id,
            phase: .terminal,
            description: subAgent.description,
            prompt: subAgent.prompt,
            agentType: subAgent.agentType,
            input: subAgent.input,
            lastToolName: subAgent.lastToolName,
            status: "completed",
            parentToolUseId: subAgent.parentToolUseId,
            callerAgent: subAgent.callerAgent,
            parentSessionId: subAgent.parentSessionId,
            childSessionIds: subAgent.childSessionIds,
            metadata: metadata
        )
        let terminalPhaseKey = Self.subAgentPhaseKey(terminal)
        guard !state.subAgentPhaseKeys.contains(terminalPhaseKey),
              !state.subAgentTerminalIds.contains(id) else {
            return nil
        }
        state.subAgentOpenIds.remove(id)
        state.subAgentTerminalIds.insert(id)
        state.subAgentPhaseKeys.insert(terminalPhaseKey)
        return terminal
    }

    private func latestOpenSubAgent(id: String, state: ConversationState) -> AgentSubAgentEvent? {
        for envelope in state.events.reversed() {
            guard case let .subAgent(subAgent) = envelope.event,
                  subAgent.id == id else {
                continue
            }
            return subAgent.phase.isTerminal ? nil : subAgent
        }
        return nil
    }

    private func isCodexSpawnSubAgent(_ subAgent: AgentSubAgentEvent) -> Bool {
        let candidates = [
            subAgent.lastToolName,
            stringValue(subAgent.metadata["codex_collab_tool"]),
            stringValue(subAgent.input?.codexObjectValue?["codex_collab_tool"])
        ]
        return candidates.contains { candidate in
            candidate?.normalizedCodexSubAgentToolName == "spawnagent"
        }
    }

    private func terminalFailureMessage(for lifecycleState: AgentLifecycleState) -> String {
        switch lifecycleState {
        case .cancelled:
            return "Sub-agent was interrupted by host cancellation."
        case .exited, .failed:
            return "Sub-agent did not finish before the provider process ended."
        case .starting, .running:
            return "Sub-agent did not finish before the provider process ended."
        }
    }

    private static func subAgentJSONKeyPart(_ value: JSONValue?) -> String {
        guard let value else {
            return ""
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }

    private func stringValue(_ value: JSONValue?) -> String? {
        guard case let .string(string)? = value, !string.isEmpty else {
            return nil
        }
        return string
    }
}

private extension AgentEvent {
    var endsProviderTurn: Bool {
        switch self {
        case let .usage(usage):
            usage.endsActiveTurn
        case let .activity(activity):
            activity.state == .idle && activity.metadata["codex_method"] == .string("turn/completed")
        default:
            false
        }
    }
}

private extension JSONValue {
    var codexObjectValue: [String: JSONValue]? {
        guard case let .object(value) = self else {
            return nil
        }
        return value
    }
}

private extension String {
    var normalizedCodexSubAgentToolName: String {
        replacingOccurrences(of: "_", with: "").lowercased()
    }
}

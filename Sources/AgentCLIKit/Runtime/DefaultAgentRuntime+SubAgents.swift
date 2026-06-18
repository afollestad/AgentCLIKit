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
}

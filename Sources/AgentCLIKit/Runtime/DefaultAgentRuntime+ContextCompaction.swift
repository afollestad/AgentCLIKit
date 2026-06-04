import Foundation

extension DefaultAgentRuntime {
    func contextCompactionGuardedEvents(from event: AgentEvent, conversationId: AgentConversationID) -> [AgentEvent] {
        guard case let .contextCompaction(compaction) = event else {
            return [event]
        }
        guard var state = states[conversationId] else {
            return []
        }

        let phaseKey = Self.contextCompactionPhaseKey(compaction)
        guard !state.contextCompactionPhaseKeys.contains(phaseKey) else {
            states[conversationId] = state
            return []
        }
        guard !compaction.phase.isTerminal || !state.contextCompactionTerminalIds.contains(compaction.id) else {
            states[conversationId] = state
            return []
        }

        var events: [AgentEvent] = []
        if compaction.phase.isTerminal && !state.contextCompactionStartedIds.contains(compaction.id) {
            let syntheticStart = AgentContextCompactionEvent(
                id: compaction.id,
                phase: .started,
                trigger: compaction.trigger,
                metadata: compaction.metadata.merging(["synthetic": .bool(true)]) { _, new in new }
            )
            state.contextCompactionStartedIds.insert(syntheticStart.id)
            state.contextCompactionOpenIds.insert(syntheticStart.id)
            state.contextCompactionPhaseKeys.insert(Self.contextCompactionPhaseKey(syntheticStart))
            events.append(.contextCompaction(syntheticStart))
        }

        if compaction.phase == .started {
            state.contextCompactionStartedIds.insert(compaction.id)
            state.contextCompactionOpenIds.insert(compaction.id)
        }
        if compaction.phase.isTerminal {
            state.contextCompactionOpenIds.remove(compaction.id)
            state.contextCompactionTerminalIds.insert(compaction.id)
        }
        state.contextCompactionPhaseKeys.insert(phaseKey)
        let terminalFailure = compaction.phase == .started && state.lifecycleState.isTerminal
            ? terminalFailure(for: compaction.id, state: &state, lifecycleState: state.lifecycleState)
            : nil
        states[conversationId] = state
        events.append(event)
        if let failed = terminalFailure {
            events.append(.contextCompaction(failed))
        }
        return events
    }

    func emitFailedContextCompactionsForTerminalProcess(
        conversationId: AgentConversationID,
        reason: String,
        message: String
    ) {
        guard let state = states[conversationId], !state.contextCompactionOpenIds.isEmpty else {
            return
        }
        for id in state.contextCompactionOpenIds.sorted() {
            let failed = AgentContextCompactionEvent(
                id: id,
                phase: .failed,
                errorMessage: message,
                metadata: [
                    "synthetic": .bool(true),
                    "terminal_reason": .string(reason)
                ]
            )
            for event in contextCompactionGuardedEvents(from: .contextCompaction(failed), conversationId: conversationId) {
                append(event, source: .runtime, conversationId: conversationId)
            }
        }
    }

    private func terminalFailure(
        for id: String,
        state: inout ConversationState,
        lifecycleState: AgentLifecycleState
    ) -> AgentContextCompactionEvent? {
        let failed = AgentContextCompactionEvent(
            id: id,
            phase: .failed,
            errorMessage: terminalFailureMessage(for: lifecycleState),
            metadata: [
                "synthetic": .bool(true),
                "terminal_reason": .string(lifecycleState.rawValue)
            ]
        )
        let failedPhaseKey = Self.contextCompactionPhaseKey(failed)
        guard !state.contextCompactionPhaseKeys.contains(failedPhaseKey),
              !state.contextCompactionTerminalIds.contains(id) else {
            return nil
        }
        state.contextCompactionOpenIds.remove(id)
        state.contextCompactionTerminalIds.insert(id)
        state.contextCompactionPhaseKeys.insert(failedPhaseKey)
        return failed
    }

    private func terminalFailureMessage(for lifecycleState: AgentLifecycleState) -> String {
        switch lifecycleState {
        case .cancelled:
            return "Context compaction was interrupted by host cancellation."
        case .exited, .failed:
            return "Context compaction did not finish before the provider process ended."
        case .starting, .running:
            return "Context compaction did not finish before the provider process ended."
        }
    }
}

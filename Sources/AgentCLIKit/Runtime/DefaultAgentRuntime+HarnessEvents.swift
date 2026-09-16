import Foundation

extension DefaultAgentRuntime {
    func startHarnessRuntimeEvents(conversationId: AgentConversationID, processToken: UUID) async {
        guard let state = states[conversationId], state.processToken == processToken else {
            return
        }
        let context = AgentHarnessRuntimeContext(
            conversationId: conversationId,
            processToken: processToken,
            harnessSessionId: state.harnessSessionId,
            spawnConfig: state.spawnConfig
        )
        let adapter = state.adapter
        let stream = await adapter.runtimeEvents(context: context)
        let task = Task {
            for await harnessEvent in stream {
                await self.consumeHarnessRuntimeEvent(harnessEvent, conversationId: conversationId, processToken: processToken)
            }
        }
        // Teardown can reenter while the harness constructs its stream. Cancel the new consumer
        // instead of leaving a harness subscription alive after its process generation is gone.
        guard states[conversationId]?.processToken == processToken else {
            task.cancel()
            return
        }
        states[conversationId]?.harnessEventTasks.append(task)
    }

    func consumeHarnessRuntimeEvent(
        _ harnessEvent: AgentHarnessRuntimeEvent,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async {
        guard states[conversationId]?.processToken == processToken else {
            return
        }
        for event in lifecycleGuardedEvents(from: harnessEvent.event, conversationId: conversationId) {
            await recordHarnessSessionIfNeeded(from: event, conversationId: conversationId, processToken: processToken)
            guard states[conversationId]?.processToken == processToken else {
                return
            }
            if case let .lifecycle(lifecycle) = event, lifecycle.state.isTerminal {
                guard states[conversationId]?.lifecycleState.isTerminal == false else { return }
                // Embedded servers own a separate native process. Their terminal event must retire
                // the runtime process too, so the next explicit send can resume a fresh generation.
                emitFailedContextCompactionsForTerminalProcess(
                    conversationId: conversationId, reason: lifecycle.state.rawValue,
                    message: "Context compaction did not finish before the harness process ended."
                )
                emitFailedSubAgentsForTerminalProcess(
                    conversationId: conversationId, reason: lifecycle.state.rawValue,
                    message: "Sub-agent did not finish before the harness process ended."
                )
                states[conversationId]?.stdin = nil
                states[conversationId]?.stdinWriter = nil
                emitLifecycle(lifecycle.state, conversationId: conversationId, exitCode: lifecycle.exitCode, message: lifecycle.message)
                states[conversationId]?.process?.terminate()
                return
            }
            append(event, source: harnessEvent.source, conversationId: conversationId)
        }
    }
}

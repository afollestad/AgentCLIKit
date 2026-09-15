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
            append(event, source: harnessEvent.source, conversationId: conversationId)
        }
    }
}

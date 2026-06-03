import Foundation

extension DefaultAgentRuntime {
    func startProviderRuntimeEvents(conversationId: AgentConversationID, processToken: UUID) async {
        guard let state = states[conversationId], state.processToken == processToken else {
            return
        }
        let context = AgentProviderRuntimeContext(
            conversationId: conversationId,
            processToken: processToken,
            providerSessionId: state.providerSessionId,
            spawnConfig: state.spawnConfig
        )
        let adapter = state.adapter
        let stream = await adapter.runtimeEvents(context: context)
        let task = Task {
            for await providerEvent in stream {
                await self.consumeProviderRuntimeEvent(providerEvent, conversationId: conversationId, processToken: processToken)
            }
        }
        states[conversationId]?.providerEventTasks.append(task)
    }

    func consumeProviderRuntimeEvent(
        _ providerEvent: AgentProviderRuntimeEvent,
        conversationId: AgentConversationID,
        processToken: UUID
    ) async {
        guard states[conversationId]?.processToken == processToken else {
            return
        }
        await recordProviderSessionIfNeeded(from: providerEvent.event, conversationId: conversationId, processToken: processToken)
        guard states[conversationId]?.processToken == processToken else {
            return
        }
        append(providerEvent.event, source: providerEvent.source, conversationId: conversationId)
    }
}
